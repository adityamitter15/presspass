import CoreGraphics
import Foundation
import Testing
import PushupCore
import PushupSynth

@Suite("PushupFeatureExtractor")
struct PushupFeatureExtractorTests {
    private let tolerance: Float = 1e-4

    private func pose(elbow: Double = 150, _ configure: (inout SyntheticPose.Options) -> Void = { _ in }) -> [JointName: JointPoint] {
        var options = SyntheticPose.Options()
        configure(&options)
        return SyntheticPose.joints(elbowDegrees: elbow, options)
    }

    private func expectClose(_ a: [Float], _ b: [Float], tolerance: Float, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.count == b.count, sourceLocation: sourceLocation)
        for (i, (x, y)) in zip(a, b).enumerated() {
            #expect(abs(x - y) <= tolerance, "feature \(i): \(x) vs \(y)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Shape and gates

    @Test("returns 25 values for a full pose")
    func fullPoseHas25Values() throws {
        let features = try #require(PushupFeatureExtractor.extract(pose()))
        #expect(features.count == 25)
        #expect(features.count == PushupFeatureExtractor.featureDim)
        #expect(PushupFeatureExtractor.featureVersion == "v1")
        #expect(features.allSatisfy { $0.isFinite })
    }

    @Test("an empty joint set returns nil")
    func emptyReturnsNil() {
        #expect(PushupFeatureExtractor.extract([:]) == nil)
    }

    @Test("a missing confidence-gate joint returns nil", arguments: [
        JointName.leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .leftHip, .rightHip,
    ])
    func missingGateJointReturnsNil(_ name: JointName) {
        let joints = pose { $0.dropped = [name] }
        #expect(PushupFeatureExtractor.extract(joints) == nil)
    }

    @Test("hips or shoulders missing returns nil")
    func missingHipsOrShouldersReturnsNil() {
        let noHips = pose { $0.dropped = [.leftHip, .rightHip] }
        let noShoulders = pose { $0.dropped = [.leftShoulder, .rightShoulder] }
        #expect(PushupFeatureExtractor.extract(noHips) == nil)
        #expect(PushupFeatureExtractor.extract(noShoulders) == nil)
    }

    @Test("a missing neck or root returns nil (core joints must all be present)", arguments: [JointName.neck, .root])
    func missingCoreJointReturnsNil(_ name: JointName) {
        let joints = pose { $0.dropped = [name] }
        #expect(PushupFeatureExtractor.extract(joints) == nil)
    }

    @Test("mean confidence of the eight gate joints below 0.3 returns nil", arguments: [0.0, 0.1, 0.25, 0.29] as [Float])
    func lowMeanConfidenceReturnsNil(_ confidence: Float) {
        let joints = pose { $0.confidence = confidence }
        #expect(PushupFeatureExtractor.extract(joints) == nil)
    }

    @Test("mean confidence at or above 0.3 passes", arguments: [0.31, 0.5, 1.0] as [Float])
    func adequateMeanConfidencePasses(_ confidence: Float) {
        let joints = pose { $0.confidence = confidence }
        #expect(PushupFeatureExtractor.extract(joints) != nil)
    }

    @Test("the gate averages: one dead joint among confident ones still passes")
    func gateIsAMean() {
        let joints = pose { $0.confidenceOverrides = [.leftWrist: 0.0] }
        #expect(PushupFeatureExtractor.extract(joints) != nil)
    }

    @Test("the gate averages: mostly dead joints fail even if some are confident")
    func gateIsAMeanFails() {
        let joints = pose {
            $0.confidence = 0.9
            $0.confidenceOverrides = [
                .leftShoulder: 0.0, .rightShoulder: 0.0, .leftElbow: 0.0,
                .rightElbow: 0.0, .leftWrist: 0.0, .rightWrist: 0.5,
            ]
        }
        // (0.5 + 0.9 + 0.9) / 8 = 0.2875
        #expect(PushupFeatureExtractor.extract(joints) == nil)
    }

    @Test("joint confidence outside the gate set does not matter")
    func nonGateConfidenceIgnored() {
        let joints = pose {
            $0.confidenceOverrides = [.nose: 0, .leftKnee: 0, .rightKnee: 0, .neck: 0, .root: 0]
        }
        #expect(PushupFeatureExtractor.extract(joints) != nil)
    }

    @Test("zero torso length returns nil")
    func zeroTorsoReturnsNil() {
        var joints = pose()
        joints[.leftShoulder] = joints[.leftHip]
        joints[.rightShoulder] = joints[.rightHip]
        #expect(PushupFeatureExtractor.extract(joints) == nil)
    }

    @Test("torso length just above epsilon is accepted, below it is not")
    func torsoEpsilon() {
        func withTorso(_ length: CGFloat) -> [JointName: JointPoint] {
            var joints = pose()
            let lh = joints[.leftHip]!, rh = joints[.rightHip]!
            joints[.leftShoulder] = JointPoint(x: lh.x, y: lh.y + length, confidence: 0.9)
            joints[.rightShoulder] = JointPoint(x: rh.x, y: rh.y + length, confidence: 0.9)
            return joints
        }
        #expect(PushupFeatureExtractor.extract(withTorso(1e-8)) == nil)
        #expect(PushupFeatureExtractor.extract(withTorso(1e-3)) != nil)
    }

    // MARK: Invariances

    @Test("output is invariant to translation", arguments: [
        CGPoint(x: 0.1, y: 0), CGPoint(x: -0.2, y: 0.3), CGPoint(x: 5, y: -7),
    ])
    func translationInvariant(_ shift: CGPoint) throws {
        let base = try #require(PushupFeatureExtractor.extract(pose()))
        let moved = try #require(PushupFeatureExtractor.extract(pose { $0.translation = shift }))
        expectClose(base, moved, tolerance: tolerance)
    }

    @Test("output is invariant to uniform scale", arguments: [0.25, 0.5, 2.0, 4.0] as [CGFloat])
    func scaleInvariant(_ scale: CGFloat) throws {
        let base = try #require(PushupFeatureExtractor.extract(pose()))
        let scaled = try #require(PushupFeatureExtractor.extract(pose { $0.scale = scale }))
        expectClose(base, scaled, tolerance: tolerance)
    }

    @Test("output is invariant to scale and translation together")
    func scaleAndTranslationInvariant() throws {
        let base = try #require(PushupFeatureExtractor.extract(pose(elbow: 100)))
        let moved = try #require(PushupFeatureExtractor.extract(pose(elbow: 100) {
            $0.scale = 0.6
            $0.translation = CGPoint(x: 0.07, y: -0.11)
        }))
        expectClose(base, moved, tolerance: tolerance)
    }

    // MARK: Mirror rule

    @Test("mirroring a leaning pose left-right about the hip centre gives identical features")
    func mirroredPoseGivesSameFeatures() throws {
        // Documented rule: if the shoulder centre is left of the hip centre,
        // every x is negated. A leaning pose and its mirror image therefore
        // normalise to the same vector.
        for elbow in [80.0, 120.0, 165.0] {
            let original = try #require(PushupFeatureExtractor.extract(pose(elbow: elbow) { $0.lean = 0.05 }))
            let mirrored = try #require(PushupFeatureExtractor.extract(pose(elbow: elbow) {
                $0.lean = 0.05
                $0.mirrored = true
            }))
            expectClose(original, mirrored, tolerance: tolerance)
        }
    }

    @Test("the normalised neck x is never negative, whichever way the pose leans", arguments: [-0.08, -0.02, 0.02, 0.08] as [CGFloat])
    func neckXNeverNegative(_ lean: CGFloat) throws {
        let features = try #require(PushupFeatureExtractor.extract(pose { $0.lean = lean }))
        let neckXIndex = 16
        #expect(features[neckXIndex] >= 0)
    }

    @Test("a lean to either side gives the same angles, since the mirror rule removes the side")
    func leanSidesAgree() throws {
        let right = try #require(PushupFeatureExtractor.extract(pose { $0.lean = 0.05 }))
        let left = try #require(PushupFeatureExtractor.extract(pose { $0.lean = -0.05 }))
        // Elbow angles (20, 21) and torso-vs-horizontal (24) do not depend on
        // which side the lean is on.
        for index in [20, 21, 24] {
            #expect(abs(right[index] - left[index]) < 1e-3, "feature \(index)")
        }
    }

    @Test("root is the hip centre, so it normalises to the origin")
    func rootAtOrigin() throws {
        let features = try #require(PushupFeatureExtractor.extract(pose()))
        #expect(abs(features[18]) < tolerance)
        #expect(abs(features[19]) < tolerance)
    }

    @Test("neck sits one torso length above the hip centre after normalisation")
    func neckAtUnitDistance() throws {
        let features = try #require(PushupFeatureExtractor.extract(pose()))
        let neck = hypot(Double(features[16]), Double(features[17]))
        // Neck is the shoulder centre by construction in the synthetic pose.
        #expect(abs(neck - 1.0) < 1e-3)
    }

    // MARK: Angles

    @Test("a straight arm gives an elbow angle of pi")
    func straightArmIsPi() throws {
        let features = try #require(PushupFeatureExtractor.extract(pose(elbow: 180)))
        #expect(abs(features[PushupFeatureExtractor.leftElbowAngleIndex] - .pi) < 1e-3)
        #expect(abs(features[PushupFeatureExtractor.rightElbowAngleIndex] - .pi) < 1e-3)
    }

    @Test("a right-angled arm gives an elbow angle of pi/2")
    func rightAngleIsHalfPi() throws {
        let features = try #require(PushupFeatureExtractor.extract(pose(elbow: 90)))
        #expect(abs(features[PushupFeatureExtractor.leftElbowAngleIndex] - .pi / 2) < 1e-3)
        #expect(abs(features[PushupFeatureExtractor.rightElbowAngleIndex] - .pi / 2) < 1e-3)
    }

    @Test("elbow angle features equal the constructed angle", arguments: [45.0, 70.0, 80.0, 100.0, 120.0, 145.0, 165.0, 175.0])
    func elbowAngleMatchesConstruction(_ degrees: Double) throws {
        let features = try #require(PushupFeatureExtractor.extract(pose(elbow: degrees)))
        let expected = Float(degrees * .pi / 180)
        #expect(abs(features[PushupFeatureExtractor.leftElbowAngleIndex] - expected) < 1e-3)
        #expect(abs(features[PushupFeatureExtractor.rightElbowAngleIndex] - expected) < 1e-3)
    }

    @Test("the synthetic pose really has the requested elbow angle (guards the test helper)")
    func syntheticPoseGeometry() throws {
        let joints = pose(elbow: 110)
        let left = SyntheticPose.angleDegrees(
            vertex: try #require(joints[.leftElbow]),
            try #require(joints[.leftShoulder]),
            try #require(joints[.leftWrist])
        )
        #expect(abs(left - 110) < 0.01)
    }

    @Test("all angle features lie in [0, pi]")
    func anglesInRange() throws {
        for elbow in stride(from: 30.0, through: 180.0, by: 15.0) {
            let features = try #require(PushupFeatureExtractor.extract(pose(elbow: elbow)))
            for index in 20..<25 {
                #expect(features[index] >= 0 && features[index] <= .pi + 1e-6)
            }
        }
    }

    // MARK: Ankle fallback

    /// Angle at `vertex` between the rays to `a` and `b`, in radians.
    private func angle(_ vertex: JointPoint, _ a: JointPoint, _ b: JointPoint) -> Float {
        Float(SyntheticPose.angleDegrees(vertex: vertex, a, b) * .pi / 180)
    }

    /// Angle in [0, pi] between (from -> to) and the positive x axis.
    private func angleToHorizontal(from: JointPoint, to: JointPoint) -> Float {
        Float(atan2(Double(to.y - from.y), Double(to.x - from.x)))
    }

    @Test("with confident ankles the body-line angle is the shoulder-hip-ankle angle")
    func ankleBodyLineAngle() throws {
        let joints = pose()
        let features = try #require(PushupFeatureExtractor.extract(joints))
        let left = angle(joints[.leftHip]!, joints[.leftShoulder]!, joints[.leftAnkle]!)
        let right = angle(joints[.rightHip]!, joints[.rightShoulder]!, joints[.rightAnkle]!)
        #expect(abs(features[22] - left) < 1e-3)
        #expect(abs(features[23] - right) < 1e-3)
    }

    @Test("a missing ankle falls back to the shoulder-hip vector against the horizontal", arguments: [true, false])
    func missingAnkleFallsBack(_ left: Bool) throws {
        let joints = pose { $0.dropped = [left ? .leftAnkle : .rightAnkle] }
        let features = try #require(PushupFeatureExtractor.extract(joints))
        let side: JointName = left ? .leftHip : .rightHip
        let shoulder: JointName = left ? .leftShoulder : .rightShoulder
        let expected = angleToHorizontal(from: joints[side]!, to: joints[shoulder]!)
        let index = left ? 22 : 23
        #expect(abs(features[index] - expected) < 1e-3)

        // And it differs from the ankle-based value on the untouched side's index.
        let full = try #require(PushupFeatureExtractor.extract(pose()))
        #expect(abs(features[index] - full[index]) > 0.5)
    }

    @Test("a low-confidence ankle falls back, same as a missing one")
    func lowConfidenceAnkleFallsBack() throws {
        let missing = try #require(PushupFeatureExtractor.extract(pose { $0.dropped = [.leftAnkle, .rightAnkle] }))
        let lowConf = try #require(PushupFeatureExtractor.extract(pose {
            $0.confidenceOverrides = [.leftAnkle: 0.1, .rightAnkle: 0.29]
        }))
        expectClose(missing, lowConf, tolerance: tolerance)
    }

    @Test("an ankle at exactly the confidence threshold is used")
    func ankleAtThresholdIsUsed() throws {
        let full = try #require(PushupFeatureExtractor.extract(pose()))
        let atThreshold = try #require(PushupFeatureExtractor.extract(pose {
            $0.confidenceOverrides = [.leftAnkle: 0.3, .rightAnkle: 0.3]
        }))
        expectClose(full, atThreshold, tolerance: tolerance)
    }

    @Test("optional joints (nose, knees) do not affect the features")
    func optionalJointsIgnored() throws {
        let full = try #require(PushupFeatureExtractor.extract(pose()))
        let trimmed = try #require(PushupFeatureExtractor.extract(pose {
            $0.dropped = [.nose, .leftKnee, .rightKnee]
        }))
        expectClose(full, trimmed, tolerance: tolerance)
    }

    // MARK: Torso angle

    @Test("an upright torso is about pi/2 against the horizontal")
    func uprightTorsoAngle() throws {
        let features = try #require(PushupFeatureExtractor.extract(pose { $0.lean = 0.0001 }))
        #expect(abs(features[24] - .pi / 2) < 0.05)
    }
}
