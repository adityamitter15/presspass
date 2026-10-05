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

    /// Called with each camera frame's sample buffer, on the pose queue,
    /// after the timestamp check and before the frame goes to MediaPipe, so
    /// it fires once for every frame that is delivered as a pose frame. Must
    /// return quickly. May be set from any queue: access is lock-guarded
    /// because the pose queue reads it for every frame.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)? {
        get {
            sampleBufferLock.lock()
            defer { sampleBufferLock.unlock() }
            return sampleBufferHandler
        }
        set {
            sampleBufferLock.lock()
            sampleBufferHandler = newValue
            sampleBufferLock.unlock()
        }
    }
    private let sampleBufferLock = NSLock()
    private var sampleBufferHandler: ((CMSampleBuffer) -> Void)?

    /// Called on `deliveryQueue` when the system interrupts the camera, with
    /// a plain-language reason, and with nil when it resumes. Without this
    /// an interruption shows as a silent black preview.
    var onInterruption: ((String?) -> Void)?

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
        observeSession()
    }

    private var sessionObservers: [NSObjectProtocol] = []
    #if DEBUG
    private var diagnosticFrameCount = 0
    #endif

    /// Watches the capture session's lifecycle. The system can take the
    /// camera away at any time (another app sharing the screen, a call,
    /// heat), and the session then simply stops delivering frames, so the
    /// interruption has to be reported or the screen just goes black.
    private func observeSession() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ label: String, _ handler: @escaping (Notification) -> Void) {
            let observer = center.addObserver(forName: name, object: captureSession, queue: nil) { note in
                #if DEBUG
                var detail = ""
                if let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                    detail += " error=\(error.domain) \(error.code) \(error.localizedDescription)"
                }
                if let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
                    detail += " reason=\(reason)"
                }
                CameraDiagnostics.log("session \(label)\(detail)")
                #endif
                handler(note)
            }
            sessionObservers.append(observer)
        }

        observe(AVCaptureSession.didStartRunningNotification, "didStartRunning") { _ in }
        observe(AVCaptureSession.didStopRunningNotification, "didStopRunning") { _ in }
        observe(AVCaptureSession.wasInterruptedNotification, "wasInterrupted") { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.reportInterruption(Self.message(for: reason))
        }
        observe(AVCaptureSession.interruptionEndedNotification, "interruptionEnded") { [weak self] _ in
            self?.reportInterruption(nil)
        }
        observe(AVCaptureSession.runtimeErrorNotification, "runtimeError") { [weak self] _ in
            guard let self else { return }
            self.reportInterruption("The camera stopped unexpectedly. Trying to restart it.")
            self.sessionQueue.async {
                if !self.captureSession.isRunning { self.captureSession.startRunning() }
                if self.captureSession.isRunning { self.reportInterruption(nil) }
            }
        }
        #if DEBUG
        CameraDiagnostics.log("CameraPoseSession created")
        #endif
    }

    private func reportInterruption(_ message: String?) {
        deliveryQueue.async { [weak self] in self?.onInterruption?(message) }
    }

    private static func message(for reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "iOS has paused the camera because something else is sharing the screen: a picture-in-picture video, a call, or iPhone Mirroring from a Mac. Close it and the camera comes back."
        case .videoDeviceInUseByAnotherClient:
            return "Another app is using the camera. Close it and the camera comes back."
        case .videoDeviceNotAvailableInBackground:
            return "The camera pauses while PressPass is in the background."
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "The phone is too hot or too busy to run the camera. Give it a minute to cool down."
        default:
            return "iOS has paused the camera. It should come back by itself."
        }
    }

    deinit {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        #if DEBUG
        CameraDiagnostics.log("CameraPoseSession released")
        #endif
    }

    /// Requests camera access (if not already determined) and, once
    /// granted, configures and starts the capture session. Safe to call
    /// more than once. `completion` reports whether the session actually
    /// started running.
    func start(completion: @escaping (Result<Void, SessionError>) -> Void) {
        #if DEBUG
        CameraDiagnostics.log("start() authorization=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) (0 undetermined, 1 restricted, 2 denied, 3 authorized)")
        #endif
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
        #if DEBUG
        CameraDiagnostics.log("stop() requested")
        #endif
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    /// Builds a fresh preview layer wired to this session. Callers own the
    /// layer's placement/sizing.
    func makeCameraPreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        #if DEBUG
        CameraDiagnostics.log("preview layer created")
        #endif
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
                #if DEBUG
                CameraDiagnostics.log("configure: reused existing inputs, isRunning=\(self.captureSession.isRunning) interrupted=\(self.captureSession.isInterrupted)")
                #endif
                self.deliveryQueue.async { completion(.success(())) }
                return
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                #if DEBUG
                CameraDiagnostics.log("configure: no front camera device or input could not be created")
                #endif
                self.deliveryQueue.async { completion(.failure(.cameraUnavailable)) }
                return
            }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high
            // Where the system allows it, keep the camera while another app
            // shares the screen (picture in picture, Split View) instead of
            // being interrupted.
            if self.captureSession.isMultitaskingCameraAccessSupported {
                self.captureSession.isMultitaskingCameraAccessEnabled = true
            }
            #if DEBUG
            CameraDiagnostics.log("configure: multitaskingCameraAccessSupported=\(self.captureSession.isMultitaskingCameraAccessSupported)")
            #endif

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
            #if DEBUG
            CameraDiagnostics.log("configure: inputs=\(self.captureSession.inputs.count) outputs=\(self.captureSession.outputs.count) connections=\(self.captureSession.connections.count) isRunning=\(self.captureSession.isRunning) interrupted=\(self.captureSession.isInterrupted)")
            #endif
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
        #if DEBUG
        diagnosticFrameCount += 1
        if [1, 30, 150].contains(diagnosticFrameCount) {
            let size = CMSampleBufferGetImageBuffer(sampleBuffer).map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none"
            CameraDiagnostics.log("camera frame \(diagnosticFrameCount) received, size=\(size)")
        }
        #endif
        let timestamp = Date().timeIntervalSince(captureStartDate)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds: TimeInterval? = presentationTime.isNumeric ? presentationTime.seconds : nil

        guard let landmarker = poseLandmarker else {
            if !didLogLandmarkerFailure {
                didLogLandmarkerFailure = true
                os_log(.error, log: Self.log, "no PoseLandmarker available; delivering empty pose frames")
            }
            // Still a delivered pose frame (with no joints), so it still gets video.
            onSampleBuffer?(sampleBuffer)
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

        onSampleBuffer?(sampleBuffer)

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
