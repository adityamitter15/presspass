import CoreGraphics
import Foundation

/// Converts a BlazePose (MediaPipe `PoseLandmarker`) result into this
/// pipeline's `PoseFrame` contract.
///
/// BlazePose reports 33 landmarks (`RawLandmark`) per pose, `x`/`y` normalized
/// to [0, 1] with the origin at the TOP-left and y increasing DOWNWARD, plus
/// a `visibility` score. `PoseFrame`'s convention is the opposite on y
/// (origin bottom-left, y up), see `PoseFrame.swift`, so every landmark is
/// flipped on the way in.
public enum BlazePoseMapping {
    /// Landmark indices this pipeline uses, per the BlazePose topology:
    /// https://developers.google.com/mediapipe/solutions/vision/pose_landmarker
    private static let landmarkIndex: [JointName: Int] = [
        .nose: 0,
        .leftShoulder: 11,
        .rightShoulder: 12,
        .leftElbow: 13,
        .rightElbow: 14,
        .leftWrist: 15,
        .rightWrist: 16,
        .leftHip: 23,
        .rightHip: 24,
        .leftKnee: 25,
        .rightKnee: 26,
        .leftAnkle: 27,
        .rightAnkle: 28,
    ]

    /// Landmarks below this visibility are treated as not detected at all
    /// (omitted from the resulting `PoseFrame`), matching how Vision simply
    /// omitted joints it couldn't locate.
    private static let minVisibility: Float = 0.1

    /// Builds a `PoseFrame` from one pose's 33 BlazePose landmarks. Passing
    /// an empty or short array (e.g. because nothing was detected) yields a
    /// frame with no joints, which downstream code already treats as the
    /// "no body detected" case.
    public static func poseFrame(timestamp: TimeInterval, landmarks: [RawLandmark]) -> PoseFrame {
        guard landmarks.count >= 29 else {
            return PoseFrame(timestamp: timestamp, joints: [:])
        }

        var joints: [JointName: JointPoint] = [:]
        for (jointName, index) in landmarkIndex {
            guard let point = jointPoint(landmarks[index]) else { continue }
            joints[jointName] = point
        }

        if let neck = midpoint(joints[.leftShoulder], joints[.rightShoulder]) {
            joints[.neck] = neck
        }
        if let root = midpoint(joints[.leftHip], joints[.rightHip]) {
            joints[.root] = root
        }

        return PoseFrame(timestamp: timestamp, joints: joints)
    }

    /// Converts one landmark into a `JointPoint` in `PoseFrame`'s
    /// convention, or `nil` if its visibility is too low to trust.
    private static func jointPoint(_ landmark: RawLandmark) -> JointPoint? {
        // Absent visibility (e.g. a model variant that doesn't emit it) is
        // treated as a middling 0.5 confidence rather than "fully visible",
        // so it doesn't masquerade as a confident detection downstream.
        let confidence = landmark.visibility?.clamped01() ?? 0.5
        guard confidence >= minVisibility else { return nil }
        return JointPoint(x: CGFloat(landmark.x), y: 1 - CGFloat(landmark.y), confidence: confidence)
    }

    /// Midpoint of two joints with the same convention, confidence the
    /// minimum of the two parents'. `nil` if either parent is missing.
    private static func midpoint(_ a: JointPoint?, _ b: JointPoint?) -> JointPoint? {
        guard let a, let b else { return nil }
        return JointPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, confidence: min(a.confidence, b.confidence))
    }
}

private extension Float {
    func clamped01() -> Float {
        min(max(self, 0), 1)
    }
}
