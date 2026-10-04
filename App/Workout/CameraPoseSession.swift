import AVFoundation
import CoreImage
import MediaPipeTasksVision
import PushupCore
import UIKit
import os.log

/// Owns the front-camera capture pipeline and runs BlazePose (MediaPipe
/// `PoseLandmarker`) body-pose detection on every frame. Delivers
/// `PoseFrame`s via `onFrame` and the detector's raw output via
/// `onRawFrame`, both called on `deliveryQueue` (main by default) so callers
/// can update UI state directly without an extra hop.
final class CameraPoseSession: NSObject {
    enum SessionError: Error {
        case cameraUnavailable
        case notAuthorized
    }

    /// Called with every successfully-decoded pose frame. May be called
    /// even when no body was detected (with an empty `joints` dict) so
    /// callers can drive a "no body detected" placement hint.
    var onFrame: ((PoseFrame) -> Void)?

    /// Called with the same frames as `onFrame`, just before it, carrying the
    /// detector's raw landmarks (image and world) and the camera
    /// presentation time. Used by the DEBUG recorder.
    var onRawFrame: ((RawPoseFrame) -> Void)?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.addymitter.pushuptime.camera.session")
    private let poseQueue = DispatchQueue(label: "com.addymitter.pushuptime.camera.pose")
    private let deliveryQueue: DispatchQueue
    private let captureStartDate = Date()
    private static let log = OSLog(subsystem: "com.addymitter.pushuptime", category: "CameraPoseSession")

    /// Created once, lazily, on the pose queue. `nil` if the model asset
    /// couldn't be found/loaded, in which case every frame is delivered
    /// with empty joints (the existing "not detected" UX handles this).
    private lazy var poseLandmarker: PoseLandmarker? = makePoseLandmarker()
    private var didLogLandmarkerFailure = false

    /// MediaPipe's video running mode requires strictly increasing
    /// timestamps; frames whose presentation time doesn't advance past the
    /// last one submitted are skipped rather than passed through.
    private var lastSubmittedTimestampMs: Int?

    init(deliveryQueue: DispatchQueue = .main) {
        self.deliveryQueue = deliveryQueue
        super.init()
    }

    /// Requests camera access (if not already determined) and, once
    /// granted, configures and starts the capture session. Safe to call
    /// more than once. `completion` reports whether the session actually
    /// started running.
    func start(completion: @escaping (Result<Void, SessionError>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart(completion: completion)
                } else {
                    self.deliveryQueue.async { completion(.failure(.notAuthorized)) }
                }
            }
        case .denied, .restricted:
            deliveryQueue.async { completion(.failure(.notAuthorized)) }
        @unknown default:
            deliveryQueue.async { completion(.failure(.notAuthorized)) }
        }
    }

    func stop() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    /// Builds a fresh preview layer wired to this session. Callers own the
    /// layer's placement/sizing.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    private func configureAndStart(completion: @escaping (Result<Void, SessionError>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.captureSession.inputs.isEmpty {
                // Already configured from a previous start() call.
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                self.deliveryQueue.async { completion(.success(())) }
                return
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                self.deliveryQueue.async { completion(.failure(.cameraUnavailable)) }
                return
            }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }

            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.poseQueue)
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }

            if let connection = self.videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                // Front camera preview is mirrored by convention; keep the
                // captured buffer un-mirrored so joint left/right labels
                // match the user's actual left/right.
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            self.deliveryQueue.async { completion(.success(())) }
        }
    }

    private func makePoseLandmarker() -> PoseLandmarker? {
        guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") else {
            os_log(.error, log: Self.log, "pose_landmarker_full.task not found in bundle")
            return nil
        }

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video
        options.minPoseDetectionConfidence = 0.3
        options.minPosePresenceConfidence = 0.3
        options.minTrackingConfidence = 0.3
        options.numPoses = 1

        do {
            return try PoseLandmarker(options: options)
        } catch {
            os_log(.error, log: Self.log, "failed to create PoseLandmarker: %{public}@", error.localizedDescription)
            return nil
        }
    }
}

extension CameraPoseSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = Date().timeIntervalSince(captureStartDate)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds: TimeInterval? = presentationTime.isNumeric ? presentationTime.seconds : nil

        guard let landmarker = poseLandmarker else {
            if !didLogLandmarkerFailure {
                didLogLandmarkerFailure = true
                os_log(.error, log: Self.log, "no PoseLandmarker available; delivering empty pose frames")
            }
            deliver(RawPoseFrame(timestamp: timestamp, presentationTime: presentationSeconds, landmarks: nil, worldLandmarks: nil))
            return
        }

        let timestampMs = Int((presentationTime.seconds * 1000).rounded())
        if let last = lastSubmittedTimestampMs, timestampMs <= last {
            // Video mode requires strictly increasing timestamps; drop this
            // frame rather than feed MediaPipe a non-advancing one.
            return
        }
        lastSubmittedTimestampMs = timestampMs

        guard let mpImage = try? MPImage(sampleBuffer: sampleBuffer) else {
            deliver(RawPoseFrame(timestamp: timestamp, presentationTime: presentationSeconds, landmarks: nil, worldLandmarks: nil))
            return
        }

        let result = try? landmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestampMs)
        deliver(RawPoseFrame(
            timestamp: timestamp,
            presentationTime: presentationSeconds,
            landmarks: result?.landmarks.first?.map(RawLandmark.init),
            worldLandmarks: result?.worldLandmarks.first?.map(RawLandmark.init)
        ))
    }

    /// Derives the `PoseFrame` from the raw frame and hands both to the
    /// delivery queue in one block, raw first.
    private func deliver(_ raw: RawPoseFrame) {
        let frame = BlazePoseMapping.poseFrame(from: raw)
        deliveryQueue.async { [onRawFrame, onFrame] in
            onRawFrame?(raw)
            onFrame?(frame)
        }
    }
}
