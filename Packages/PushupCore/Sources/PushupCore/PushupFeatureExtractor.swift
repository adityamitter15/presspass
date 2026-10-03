import CoreGraphics
import Foundation

/// Swift mirror of `training/features.py` ("v1" feature contract). Any
/// change here must be made identically on the Python side (and vice
/// versa): the two are the same algorithm in two languages, not two
/// independent implementations, otherwise a model trained on one won't
/// match inference on the other.
public enum PushupFeatureExtractor {

    /// Matches `FEATURE_DIM` in features.py.
    public static let featureDim = 25

    /// Matches `FEATURE_VERSION` in features.py. Bump alongside the Python
    /// constant any time the algorithm below changes.
    public static let featureVersion = "v1"

    /// Feature vector indices of the two elbow angles (radians), for callers
    /// that read them back out of the vector (the heuristic classifier, debug
    /// HUD) so nobody hardcodes the layout.
    public static let leftElbowAngleIndex = 20
    public static let rightElbowAngleIndex = 21

    /// Matches `_CONF_CHECK_JOINTS`.
    private static let confCheckJoints: [JointName] = [
        .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
    ]
    private static let minMeanConfidence: Float = 0.3

    /// Matches `_ANKLE_CONF_THRESHOLD`.
    private static let ankleConfThreshold: Float = 0.3

    private static let eps: CGFloat = 1e-6

    /// Matches `_CORE_JOINTS`, in order.
    private static let coreJoints: [JointName] = [
        .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
        .neck, .root,
    ]

    /// Extracts the 25-dim feature vector for one frame's joints, or nil
    /// if the frame fails the confidence gate or is missing joints needed
    /// for normalization. Mirrors `extract_features()` in features.py.
    public static func extract(_ joints: [JointName: JointPoint]) -> [Float]? {
        // 1. Confidence gate.
        var confSum: Float = 0
        for name in confCheckJoints {
            guard let v = joints[name] else { return nil }
            confSum += v.confidence
        }
        if confSum / Float(confCheckJoints.count) < minMeanConfidence {
            return nil
        }

        guard let hipCenter = meanPoint(joints, [.leftHip, .rightHip]),
              let shoulderCenter = meanPoint(joints, [.leftShoulder, .rightShoulder]) else {
            return nil
        }

        let torsoLength = hypot(shoulderCenter.x - hipCenter.x, shoulderCenter.y - hipCenter.y)
        if torsoLength < eps {
            return nil
        }

        let mirror: CGFloat = (shoulderCenter.x - hipCenter.x) < 0 ? -1.0 : 1.0

        func normXY(_ name: JointName) -> (x: CGFloat, y: CGFloat)? {
            guard let v = joints[name] else { return nil }
            let x = mirror * (v.x - hipCenter.x) / torsoLength
            let y = (v.y - hipCenter.y) / torsoLength
            return (x, y)
        }

        var normalized: [JointName: (x: CGFloat, y: CGFloat)] = [:]
        for name in JointName.allCases {
            if let p = normXY(name) {
                normalized[name] = p
            }
        }

        // All 10 core joints must be present post-normalization.
        for name in coreJoints {
            if normalized[name] == nil { return nil }
        }

        var feats: [Float] = []
        feats.reserveCapacity(featureDim)
        for name in coreJoints {
            let p = normalized[name]!
            feats.append(Float(p.x))
            feats.append(Float(p.y))
        }

        func elbowAngle(shoulder: JointName, elbow: JointName, wrist: JointName) -> Float {
            guard let s = normalized[shoulder], let e = normalized[elbow], let w = normalized[wrist] else {
                return 0
            }
            return angleAtVertex(e, s, w)
        }
        feats.append(elbowAngle(shoulder: .leftShoulder, elbow: .leftElbow, wrist: .leftWrist))
        feats.append(elbowAngle(shoulder: .rightShoulder, elbow: .rightElbow, wrist: .rightWrist))

        func bodyLineAngle(shoulder: JointName, hip: JointName, ankle: JointName) -> Float {
            guard let s = normalized[shoulder], let h = normalized[hip] else { return 0 }
            let rawAnkle = joints[ankle]
            let ankleOK = (rawAnkle != nil) && (rawAnkle!.confidence >= ankleConfThreshold) && (normalized[ankle] != nil)
            if ankleOK, let a = normalized[ankle] {
                return angleAtVertex(h, s, a)
            }
            let v = (x: s.x - h.x, y: s.y - h.y)
            return vecAngleToHorizontal(v)
        }
        feats.append(bodyLineAngle(shoulder: .leftShoulder, hip: .leftHip, ankle: .leftAnkle))
        feats.append(bodyLineAngle(shoulder: .rightShoulder, hip: .rightHip, ankle: .rightAnkle))

        // Torso-vs-horizontal: hip_center is the origin post-normalization,
        // so this is just the normalized shoulder_center treated as a vector.
        let torsoVec = (
            x: mirror * (shoulderCenter.x - hipCenter.x) / torsoLength,
            y: (shoulderCenter.y - hipCenter.y) / torsoLength
        )
        feats.append(vecAngleToHorizontal(torsoVec))

        assert(feats.count == featureDim)
        return feats
    }

    private static func meanPoint(_ joints: [JointName: JointPoint], _ names: [JointName]) -> (x: CGFloat, y: CGFloat)? {
        var xs: CGFloat = 0
        var ys: CGFloat = 0
        for name in names {
            guard let v = joints[name] else { return nil }
            xs += v.x
            ys += v.y
        }
        return (xs / CGFloat(names.count), ys / CGFloat(names.count))
    }

    /// Angle in [0, pi] between vector v=(x, y) and the positive-x horizontal axis.
    private static func vecAngleToHorizontal(_ v: (x: CGFloat, y: CGFloat)) -> Float {
        let norm = hypot(v.x, v.y)
        if norm < eps { return 0 }
        let cosA = max(-1.0, min(1.0, v.x / norm))
        return Float(acos(cosA))
    }

    /// Angle in [0, pi] at `vertex`, between rays vertex->a and vertex->b.
    private static func angleAtVertex(
        _ vertex: (x: CGFloat, y: CGFloat),
        _ a: (x: CGFloat, y: CGFloat),
        _ b: (x: CGFloat, y: CGFloat)
    ) -> Float {
        let v1 = (x: a.x - vertex.x, y: a.y - vertex.y)
        let v2 = (x: b.x - vertex.x, y: b.y - vertex.y)
        let n1 = hypot(v1.x, v1.y)
        let n2 = hypot(v2.x, v2.y)
        if n1 < eps || n2 < eps { return 0 }
        let dot = v1.x * v2.x + v1.y * v2.y
        let cosA = max(-1.0, min(1.0, dot / (n1 * n2)))
        return Float(acos(cosA))
    }
}
