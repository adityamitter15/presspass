import CoreGraphics
import Foundation

/// Anti-cheat checks applied to every frame before the rep counter sees it.
/// Both gates read raw joints, independent of the classifier.
public enum PostureGate {
    /// Joints whose confidence gates the rep counter's anti-cheat check
    /// (wrists, shoulders, hips: the joints most load-bearing for
    /// distinguishing a real pushup from an approximation of one).
    public static let requiredJoints: [JointName] = [
        .leftWrist, .rightWrist,
        .leftShoulder, .rightShoulder,
        .leftHip, .rightHip,
    ]

    /// Front-view posture gate: in pushup position with the phone on the
    /// floor facing the user, both wrists sit clearly below the shoulders
    /// in the image (hands planted). Standing arm-waves and most other
    /// cheats put the wrists at or above shoulder height. `PoseFrame`'s y
    /// axis points up, so "below in the image" means a smaller y.
    public static let wristBelowShoulderMargin: CGFloat = 0.03

    /// True when every joint in `requiredJoints` is present and at or above
    /// `RepCounter.requiredJointConfidenceFloor`.
    public static func requiredJointsConfident(_ joints: [JointName: JointPoint]) -> Bool {
        requiredJoints.allSatisfy { name in
            (joints[name]?.confidence ?? 0) >= RepCounter.requiredJointConfidenceFloor
        }
    }

    public static func isPushupPosture(_ joints: [JointName: JointPoint]) -> Bool {
        guard let leftWrist = joints[.leftWrist], let rightWrist = joints[.rightWrist],
              let leftShoulder = joints[.leftShoulder], let rightShoulder = joints[.rightShoulder] else {
            return false
        }
        let wristY = (leftWrist.y + rightWrist.y) / 2
        let shoulderY = (leftShoulder.y + rightShoulder.y) / 2
        return wristY < shoulderY - wristBelowShoulderMargin
    }
}
