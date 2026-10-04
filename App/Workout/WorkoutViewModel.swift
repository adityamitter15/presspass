import AVFoundation
import Combine
import Foundation
import PushupCore
import UIKit

/// Coordinates the pose source (camera, or a replay in the Simulator),
/// feature extraction, classifier, and rep counter for one workout session,
/// and publishes the state `WorkoutView` renders. Everything downstream of the `PoseSource`
/// (feature extraction, classification, rep counting) runs synchronously
/// on the delivery queue's callback, cheap enough per-frame that it
/// doesn't need its own queue, and keeping it on the main queue means the
/// `@Published` updates below don't need an extra hop.
final class WorkoutViewModel: ObservableObject {
    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var isBodyDetected: Bool = false
    @Published private(set) var reps: Int = 0
    @Published private(set) var rejectedReps: Int = 0
    @Published private(set) var currentLabel: PoseLabel = .notPushup
    @Published private(set) var ignoreReason: RepCounterIgnoreReason = .none
    @Published private(set) var isRunning: Bool = false {
        // The phone sits untouched on the floor during a set, so it must not
        // auto-lock while a workout is running. Every path that ends a
        // workout (finish, view disappearing, camera failure) clears
        // `isRunning`, which restores the default.
        didSet { UIApplication.shared.isIdleTimerDisabled = isRunning }
    }
    @Published var cameraErrorMessage: String?

    #if DEBUG
    /// Live pipeline internals for the on-screen debug HUD.
    @Published private(set) var debugStatus: String = ""
    #endif

    private let poseSource: PoseSource
    private let pipeline: PushupPipeline

    init(
        poseSource: PoseSource = AppEnvironment.current.makePoseSource(),
        pipeline: PushupPipeline = PushupPipeline(classifier: PoseClassifierFactory.makeDefault())
    ) {
        self.poseSource = poseSource
        self.pipeline = pipeline
        self.poseSource.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
        }
    }

    /// Single preview layer for the session's lifetime. Must not be
    /// recreated per SwiftUI render: only the first layer ever gets added
    /// to the view's layer tree, so a fresh layer per `body` evaluation
    /// leaves the on-screen one unsized (blank preview). Nil when the source
    /// has no camera image (replay).
    lazy var previewLayer: AVCaptureVideoPreviewLayer? = poseSource.makePreviewLayer()

    func start() {
        cameraErrorMessage = nil
        pipeline.reset()
        reps = 0
        rejectedReps = 0
        currentLabel = .notPushup
        ignoreReason = .none
        isRunning = true

        poseSource.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                break
            case .failure(.notAuthorized):
                self.cameraErrorMessage = "Camera access is required to count pushups. Enable it in Settings."
                self.isRunning = false
            case .failure(.cameraUnavailable):
                self.cameraErrorMessage = "No front camera is available on this device."
                self.isRunning = false
            }
        }
    }

    func stop() {
        poseSource.stop()
        isRunning = false
    }

    private func handle(frame: PoseFrame) {
        latestFrame = frame
        isBodyDetected = !frame.joints.isEmpty

        let output = pipeline.process(frame)

        // Counter state only moves on frames that passed the feature
        // confidence gate, so only publish then.
        if output.features != nil {
            reps = output.reps
            rejectedReps = output.rejectedReps
            currentLabel = output.currentLabel
            ignoreReason = output.ignoreReason
        }

        #if DEBUG
        updateDebugStatus(frame: frame, output: output)
        #endif
    }

    #if DEBUG
    private func updateDebugStatus(frame: PoseFrame, output: PipelineOutput) {
        let confident = frame.joints.values.filter { $0.confidence >= 0.3 }.count
        var parts = ["joints \(frame.joints.count) (\(confident) conf)"]
        if let features = output.features {
            let leftElbow = features[PushupFeatureExtractor.leftElbowAngleIndex] * 180 / .pi
            let rightElbow = features[PushupFeatureExtractor.rightElbowAngleIndex] * 180 / .pi
            parts.append(String(format: "elbow L%.0f R%.0f", leftElbow, rightElbow))
            parts.append("posture \(PostureGate.isPushupPosture(frame.joints) ? "ok" : "BAD")")
            parts.append("label \(output.frameLabel?.rawValue ?? "-")")
        } else {
            parts.append("features: nil (conf gate)")
        }
        debugStatus = parts.joined(separator: " | ")
    }
    #endif
}
