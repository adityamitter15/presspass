import CoreGraphics
import Foundation
import PushupCore

/// Builds front-view poses geometrically, in `PoseFrame` convention (origin
/// bottom-left, y up). Shoulders are level and above the hips, wrists are
/// planted below the shoulders, and the elbows sit where the angle
/// shoulder-elbow-wrist equals the requested angle on both arms.
public enum SyntheticPose {
    // Base geometry, before scale and translation.
    static let hipCenter = CGPoint(x: 0.5, y: 0.30)
    static let torsoLength: CGFloat = 0.30
    static let shoulderHalfWidth: CGFloat = 0.09
    static let hipHalfWidth: CGFloat = 0.07
    static let upperArmLength: CGFloat = 0.12
    static let forearmLength: CGFloat = 0.12

    /// Knobs for one pose. Defaults give a confident, in-posture pose.
    public struct Options {
        public var confidence: Float = 0.9
        public var confidenceOverrides: [JointName: Float] = [:]
        public var dropped: Set<JointName> = []
        public var translation = CGPoint.zero
        /// Uniform scale about the hip centre, applied before translation.
        public var scale: CGFloat = 1
        /// Standing arm-wave cheat: wrists above the shoulders instead of
        /// planted below them. The elbow angle is unchanged.
        public var wristsAboveShoulders = false
        /// Sideways shift of the shoulder centre relative to the hip centre,
        /// in base units. Positive keeps the shoulder centre to the right of
        /// the hip centre, so the extractor's mirror sign is +1 and not
        /// decided by floating-point noise.
        public var lean: CGFloat = 0.02
        /// Mirror the whole pose left-right about the hip centre (applied
        /// after scale, before translation).
        public var mirrored = false

        public init() {}
    }

    public static func joints(elbowDegrees: Double, _ options: Options = Options()) -> [JointName: JointPoint] {
        let base = basePoints(elbowDegrees: elbowDegrees, options: options)
        var result: [JointName: JointPoint] = [:]
        for (name, p) in base where !options.dropped.contains(name) {
            var x = hipCenter.x + (p.x - hipCenter.x) * options.scale
            let y = hipCenter.y + (p.y - hipCenter.y) * options.scale
            if options.mirrored { x = 2 * hipCenter.x - x }
            result[name] = JointPoint(
                x: x + options.translation.x,
                y: y + options.translation.y,
                confidence: options.confidenceOverrides[name] ?? options.confidence
            )
        }
        return result
    }

    public static func frame(
        timestamp: TimeInterval,
        elbowDegrees: Double,
        _ options: Options = Options()
    ) -> PoseFrame {
        PoseFrame(timestamp: timestamp, joints: joints(elbowDegrees: elbowDegrees, options))
    }

    /// Frames at `fps` for `reps` pushups of `secondsPerRep` each. The elbow
    /// angle holds at `topDegrees` for `leadInSeconds`, then each rep eases
    /// smoothly (raised cosine) from top to bottom and back, then holds at
    /// the top for `leadOutSeconds` so the final up transition can register.
    public static func repSequence(
        reps: Int,
        secondsPerRep: Double,
        fps: Double = 30,
        topDegrees: Double = 165,
        bottomDegrees: Double = 80,
        leadInSeconds: Double = 1.0,
        leadOutSeconds: Double = 1.0,
        startTime: TimeInterval = 0,
        _ options: Options = Options()
    ) -> [PoseFrame] {
        let total = leadInSeconds + Double(reps) * secondsPerRep + leadOutSeconds
        let frameCount = Int((total * fps).rounded())
        return (0..<frameCount).map { i in
            let t = Double(i) / fps
            let repTime = t - leadInSeconds
            let degrees: Double
            if repTime < 0 || repTime >= Double(reps) * secondsPerRep {
                degrees = topDegrees
            } else {
                let phase = (repTime / secondsPerRep).truncatingRemainder(dividingBy: 1)
                let depth = (1 - cos(2 * .pi * phase)) / 2
                degrees = topDegrees - (topDegrees - bottomDegrees) * depth
            }
            return frame(timestamp: startTime + t, elbowDegrees: degrees, options)
        }
    }

    // MARK: - Raw landmarks

    /// Landmark indices `BlazePoseMapping` reads, mirrored here so the tests
    /// do not depend on its private table.
    private static let blazePoseIndex: [JointName: Int] = [
        .nose: 0,
        .leftShoulder: 11, .rightShoulder: 12,
        .leftElbow: 13, .rightElbow: 14,
        .leftWrist: 15, .rightWrist: 16,
        .leftHip: 23, .rightHip: 24,
        .leftKnee: 25, .rightKnee: 26,
        .leftAnkle: 27, .rightAnkle: 28,
    ]

    /// Inverse of `BlazePoseMapping`: 33 landmarks in BlazePose convention
    /// (y flipped back to top-left origin), the 13 mapped indices filled from
    /// `joints` and every other index a low-visibility placeholder. `neck`
    /// and `root` are not written, the mapping synthesises them. A joint that
    /// is absent from `joints` gets the placeholder too, so the mapping omits
    /// it again.
    public static func rawLandmarks(from joints: [JointName: JointPoint]) -> [RawLandmark] {
        let placeholder = RawLandmark(x: 0.5, y: 0.5, z: 0, visibility: 0.02, presence: 0.02)
        var landmarks = [RawLandmark](repeating: placeholder, count: 33)
        for (name, index) in blazePoseIndex {
            guard let point = joints[name] else { continue }
            landmarks[index] = RawLandmark(
                x: Float(point.x),
                y: Float(1 - point.y),
                z: 0,
                visibility: point.confidence,
                presence: 1
            )
        }
        return landmarks
    }

    /// 33 plausible world landmarks in metres, only so tests have something
    /// to round-trip. Not derived from the pose geometry.
    public static func worldLandmarks(seed: Int) -> [RawLandmark] {
        (0..<33).map { index in
            let v = Float(index + seed)
            return RawLandmark(x: sin(v) * 0.4, y: cos(v) * 0.4, z: sin(v * 0.5) * 0.2, visibility: nil, presence: nil)
        }
    }

    /// Raw frames for a synthetic pose sequence. The presentation time is the
    /// frame timestamp plus a fixed offset, as a camera clock would differ
    /// from the session clock.
    public static func rawFrames(from frames: [PoseFrame], presentationOffset: TimeInterval = 5000) -> [RawPoseFrame] {
        frames.enumerated().map { index, frame in
            RawPoseFrame(
                timestamp: frame.timestamp,
                presentationTime: frame.timestamp + presentationOffset,
                landmarks: rawLandmarks(from: frame.joints),
                worldLandmarks: worldLandmarks(seed: index)
            )
        }
    }

    /// Angle in degrees at `vertex` between the rays to `a` and `b`.
    public static func angleDegrees(vertex: JointPoint, _ a: JointPoint, _ b: JointPoint) -> Double {
        let v1 = (x: Double(a.x - vertex.x), y: Double(a.y - vertex.y))
        let v2 = (x: Double(b.x - vertex.x), y: Double(b.y - vertex.y))
        let cosA = (v1.x * v2.x + v1.y * v2.y) / (hypot(v1.x, v1.y) * hypot(v2.x, v2.y))
        return acos(max(-1, min(1, cosA))) * 180 / .pi
    }

    // MARK: - Geometry

    private static func basePoints(elbowDegrees: Double, options: Options) -> [JointName: CGPoint] {
        let sy = hipCenter.y + torsoLength
        let sx = hipCenter.x + options.lean
        let leftShoulder = CGPoint(x: sx - shoulderHalfWidth, y: sy)
        let rightShoulder = CGPoint(x: sx + shoulderHalfWidth, y: sy)
        let leftHip = CGPoint(x: hipCenter.x - hipHalfWidth, y: hipCenter.y)
        let rightHip = CGPoint(x: hipCenter.x + hipHalfWidth, y: hipCenter.y)

        let (leftElbow, leftWrist) = arm(from: leftShoulder, outward: -1, elbowDegrees: elbowDegrees, up: options.wristsAboveShoulders)
        let (rightElbow, rightWrist) = arm(from: rightShoulder, outward: 1, elbowDegrees: elbowDegrees, up: options.wristsAboveShoulders)

        return [
            .nose: CGPoint(x: sx, y: sy + 0.08),
            .neck: CGPoint(x: sx, y: sy),
            .leftShoulder: leftShoulder,
            .rightShoulder: rightShoulder,
            .leftElbow: leftElbow,
            .rightElbow: rightElbow,
            .leftWrist: leftWrist,
            .rightWrist: rightWrist,
            .leftHip: leftHip,
            .rightHip: rightHip,
            .root: hipCenter,
            .leftKnee: CGPoint(x: leftHip.x, y: hipCenter.y - 0.16),
            .rightKnee: CGPoint(x: rightHip.x, y: hipCenter.y - 0.16),
            .leftAnkle: CGPoint(x: leftHip.x, y: hipCenter.y - 0.31),
            .rightAnkle: CGPoint(x: rightHip.x, y: hipCenter.y - 0.31),
        ]
    }

    /// Places the wrist straight below (or above) the shoulder at the
    /// distance the law of cosines requires, then the elbow outward on the
    /// circle intersection, so the angle at the elbow is `elbowDegrees`.
    private static func arm(
        from shoulder: CGPoint,
        outward: CGFloat,
        elbowDegrees: Double,
        up: Bool
    ) -> (elbow: CGPoint, wrist: CGPoint) {
        let u = Double(upperArmLength)
        let f = Double(forearmLength)
        let theta = elbowDegrees * .pi / 180
        let d = (u * u + f * f - 2 * u * f * cos(theta)).squareRoot()
        let dir: CGFloat = up ? 1 : -1
        let wrist = CGPoint(x: shoulder.x, y: shoulder.y + dir * CGFloat(d))
        let along = (u * u - f * f + d * d) / (2 * d)
        let across = max(0, u * u - along * along).squareRoot()
        let elbow = CGPoint(
            x: shoulder.x + outward * CGFloat(across),
            y: shoulder.y + dir * CGFloat(along)
        )
        return (elbow, wrist)
    }
}
