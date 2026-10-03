import AVFoundation
import Combine
import Foundation

/// Coordinates the camera/pose pipeline, feature extraction, classifier,
/// and rep counter for one workout session, and publishes the state
/// `WorkoutView` renders. Everything downstream of `CameraPoseSession`
/// (feature extraction, classification, rep counting) runs synchronously
/// on the delivery queue's callback — cheap enough per-frame that it
/// doesn't need its own queue, and keeping it on the main queue means the
/// `@Published` updates below don't need an extra hop.
final class WorkoutViewModel: ObservableObject {
    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var isBodyDetected: Bool = false
    @Published private(set) var reps: Int = 0
    @Published private(set) var rejectedReps: Int = 0
    @Published private(set) var currentLabel: PoseLabel = .notPushup
    @Published private(set) var ignoreReason: RepCounterIgnoreReason = .none
    @Published private(set) var isRunning: Bool = false
    @Published var cameraErrorMessage: String?

    #if DEBUG
    /// Live pipeline internals for the on-screen debug HUD.
    @Published private(set) var debugStatus: String = ""
    #endif

    /// Joints whose confidence gates the rep counter's anti-cheat check
    /// (wrists, shoulders, hips — the joints most load-bearing for
    /// distinguishing a real pushup from an approximation of one).
    private static let requiredJoints: [JointName] = [
        .leftWrist, .rightWrist,
        .leftShoulder, .rightShoulder,
        .leftHip, .rightHip,
    ]

    private let cameraSession: CameraPoseSession
    private let classifier: PoseClassifier
    private let repCounter: RepCounter

    init(
        cameraSession: CameraPoseSession = CameraPoseSession(),
        classifier: PoseClassifier = PoseClassifierFactory.makeDefault(),
        repCounter: RepCounter = RepCounter()
    ) {
        self.cameraSession = cameraSession
        self.classifier = classifier
        self.repCounter = repCounter
        self.cameraSession.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
        }
    }

    /// Single preview layer for the session's lifetime. Must not be
    /// recreated per SwiftUI render: only the first layer ever gets added
    /// to the view's layer tree, so a fresh layer per `body` evaluation
    /// leaves the on-screen one unsized (blank preview).
    lazy var previewLayer: AVCaptureVideoPreviewLayer = cameraSession.makePreviewLayer()

    func start() {
        cameraErrorMessage = nil
        repCounter.reset()
        reps = 0
        rejectedReps = 0
        currentLabel = .notPushup
        ignoreReason = .none
        isRunning = true

        cameraSession.start { [weak self] result in
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
        cameraSession.stop()
        isRunning = false
    }

    private func handle(frame: PoseFrame) {
        latestFrame = frame
        isBodyDetected = !frame.joints.isEmpty

        guard let features = PushupFeatureExtractor.extract(frame.joints) else {
            #if DEBUG
            updateDebugStatus(frame: frame, features: nil, label: nil)
            #endif
            return
        }

        let (label, confidence) = classifier.classify(features)

        let requiredJointsConfident = Self.requiredJoints.allSatisfy { name in
            (frame.joints[name]?.confidence ?? 0) >= RepCounter.requiredJointConfidenceFloor
        }

        let input = RepCounterFrameInput(
            timestamp: frame.timestamp,
            label: label,
            labelConfidence: confidence,
            postureValid: Self.isPushupPosture(frame.joints),
            requiredJointsConfident: requiredJointsConfident
        )
        repCounter.process(input)

        reps = repCounter.reps
        rejectedReps = repCounter.rejectedReps
        currentLabel = repCounter.currentLabel
        ignoreReason = repCounter.lastIgnoreReason

        #if DEBUG
        updateDebugStatus(frame: frame, features: features, label: label)
        #endif
    }

    #if DEBUG
    private func updateDebugStatus(frame: PoseFrame, features: [Float]?, label: PoseLabel?) {
        let confident = frame.joints.values.filter { $0.confidence >= 0.3 }.count
        var parts = ["joints \(frame.joints.count) (\(confident) conf)"]
        if let features {
            let leftElbow = features[20] * 180 / .pi
            let rightElbow = features[21] * 180 / .pi
            parts.append(String(format: "elbow L%.0f R%.0f", leftElbow, rightElbow))
            parts.append("posture \(Self.isPushupPosture(frame.joints) ? "ok" : "BAD")")
            parts.append("label \(label?.rawValue ?? "-")")
        } else {
            parts.append("features: nil (conf gate)")
        }
        debugStatus = parts.joined(separator: " | ")
    }
    #endif

    /// Front-view posture gate: in pushup position with the phone on the
    /// floor facing the user, both wrists sit clearly below the shoulders
    /// in the image (hands planted). Standing arm-waves and most other
    /// cheats put the wrists at or above shoulder height. `PoseFrame`'s y
    /// axis points up, so "below in the image" means a smaller y.
    private static let wristBelowShoulderMargin: CGFloat = 0.03

    private static func isPushupPosture(_ joints: [JointName: JointPoint]) -> Bool {
        guard let leftWrist = joints[.leftWrist], let rightWrist = joints[.rightWrist],
              let leftShoulder = joints[.leftShoulder], let rightShoulder = joints[.rightShoulder] else {
            return false
        }
        let wristY = (leftWrist.y + rightWrist.y) / 2
        let shoulderY = (leftShoulder.y + rightShoulder.y) / 2
        return wristY < shoulderY - wristBelowShoulderMargin
    }
}
