import CoreGraphics
import Foundation

/// Joint set the workout module understands. Names and cases are chosen to
/// line up exactly with the `JOINT_NAMES` tuple in `training/features.py` —
/// the two lists must stay in sync, since recorded sessions and on-device
/// feature extraction both key off these raw string values.
///
/// `neck` and `root` have no direct BlazePose landmark; they're synthesized
/// as shoulder/hip midpoints — see `BlazePoseMapping.swift`.
enum JointName: String, CaseIterable, Codable {
    case nose
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case root
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
}

/// One tracked joint's position and detection confidence, normalized to
/// [0, 1] in image space. Coordinate convention: origin bottom-left, x
/// right, y up — the rest of the pipeline (`SkeletonOverlayView`,
/// `PushupFeatureExtractor`, the recording JSON contract) is built on this
/// convention, so any pose source feeding a `PoseFrame` must convert into it.
struct JointPoint {
    let x: CGFloat
    let y: CGFloat
    let confidence: Float
}

/// A single pose observation: every joint the detector reported for one
/// video frame, keyed by `JointName`. Joints the detector failed to locate
/// are simply absent from the dictionary (mirrors the recording JSON
/// contract, where a joint can be omitted from a frame entirely).
struct PoseFrame {
    let timestamp: TimeInterval
    let joints: [JointName: JointPoint]

    /// Direct initializer used by pose-detection backends, tests, and the
    /// recording pipeline's replay.
    init(timestamp: TimeInterval, joints: [JointName: JointPoint]) {
        self.timestamp = timestamp
        self.joints = joints
    }
}
