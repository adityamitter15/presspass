import CoreGraphics
import Testing
import PushupCore

@Suite("PostureGate")
struct PostureGateTests {
    /// Shoulders at y = 0.6 and wrists at `wristY`, other joints confident.
    private func joints(wristY: CGFloat, confidence: Float = 0.9) -> [JointName: JointPoint] {
        [
            .leftShoulder: JointPoint(x: 0.4, y: 0.6, confidence: confidence),
            .rightShoulder: JointPoint(x: 0.6, y: 0.6, confidence: confidence),
            .leftWrist: JointPoint(x: 0.4, y: wristY, confidence: confidence),
            .rightWrist: JointPoint(x: 0.6, y: wristY, confidence: confidence),
            .leftHip: JointPoint(x: 0.45, y: 0.3, confidence: confidence),
            .rightHip: JointPoint(x: 0.55, y: 0.3, confidence: confidence),
        ]
    }

    @Test("wrists below the shoulders by more than the margin pass", arguments: [0.5, 0.4, 0.2, 0.0] as [CGFloat])
    func wristsBelowPass(_ wristY: CGFloat) {
        #expect(PostureGate.isPushupPosture(joints(wristY: wristY)))
    }

    @Test("wrists level with or above the shoulders fail", arguments: [0.6, 0.65, 0.8, 1.0] as [CGFloat])
    func wristsLevelOrAboveFail(_ wristY: CGFloat) {
        #expect(!PostureGate.isPushupPosture(joints(wristY: wristY)))
    }

    @Test("wrists below the shoulders by less than the margin fail")
    func insideMarginFails() {
        #expect(!PostureGate.isPushupPosture(joints(wristY: 0.6 - 0.02)))
        #expect(PostureGate.isPushupPosture(joints(wristY: 0.6 - 0.04)))
        #expect(PostureGate.wristBelowShoulderMargin == 0.03)
    }

    @Test("exactly at the margin fails (strict inequality)")
    func exactlyAtMarginFails() {
        let shoulderY: CGFloat = 0.6
        let wristY = shoulderY - PostureGate.wristBelowShoulderMargin
        #expect(!PostureGate.isPushupPosture(joints(wristY: wristY)))
    }

    @Test("the average wrist height is compared with the average shoulder height")
    func usesAverages() {
        var j = joints(wristY: 0.3)
        // One wrist raised above the shoulders, the other planted far below:
        // the mean (0.35) is still clearly below the shoulders (0.6).
        j[.leftWrist] = JointPoint(x: 0.4, y: 0.65, confidence: 0.9)
        j[.rightWrist] = JointPoint(x: 0.6, y: 0.05, confidence: 0.9)
        #expect(PostureGate.isPushupPosture(j))
    }

    @Test("a missing wrist or shoulder fails", arguments: [
        JointName.leftWrist, .rightWrist, .leftShoulder, .rightShoulder,
    ])
    func missingJointFails(_ name: JointName) {
        var j = joints(wristY: 0.3)
        j[name] = nil
        #expect(!PostureGate.isPushupPosture(j))
    }

    @Test("an empty joint set fails")
    func emptyFails() {
        #expect(!PostureGate.isPushupPosture([:]))
        #expect(!PostureGate.requiredJointsConfident([:]))
    }

    @Test("posture does not depend on joint confidence")
    func postureIgnoresConfidence() {
        #expect(PostureGate.isPushupPosture(joints(wristY: 0.3, confidence: 0.0)))
    }

    @Test("the required joints are the wrists, shoulders and hips")
    func requiredJointSet() {
        #expect(Set(PostureGate.requiredJoints) == [
            .leftWrist, .rightWrist, .leftShoulder, .rightShoulder, .leftHip, .rightHip,
        ])
        #expect(PostureGate.requiredJoints.count == 6)
    }

    @Test("all six required joints at or above the floor pass")
    func allConfidentPasses() {
        #expect(PostureGate.requiredJointsConfident(joints(wristY: 0.3, confidence: 0.9)))
        #expect(PostureGate.requiredJointsConfident(joints(wristY: 0.3, confidence: 0.3)))
        #expect(RepCounter.requiredJointConfidenceFloor == 0.3)
    }

    @Test("any required joint below the floor fails", arguments: [
        JointName.leftWrist, .rightWrist, .leftShoulder, .rightShoulder, .leftHip, .rightHip,
    ])
    func oneLowJointFails(_ name: JointName) {
        var j = joints(wristY: 0.3)
        let p = j[name]!
        j[name] = JointPoint(x: p.x, y: p.y, confidence: 0.29)
        #expect(!PostureGate.requiredJointsConfident(j))
    }

    @Test("any missing required joint fails", arguments: [
        JointName.leftWrist, .rightWrist, .leftShoulder, .rightShoulder, .leftHip, .rightHip,
    ])
    func oneMissingJointFails(_ name: JointName) {
        var j = joints(wristY: 0.3)
        j[name] = nil
        #expect(!PostureGate.requiredJointsConfident(j))
    }

    @Test("joints outside the required set do not matter")
    func otherJointsIgnored() {
        var j = joints(wristY: 0.3)
        j[.leftElbow] = JointPoint(x: 0.3, y: 0.45, confidence: 0.0)
        j[.leftAnkle] = JointPoint(x: 0.3, y: 0.0, confidence: 0.0)
        #expect(PostureGate.requiredJointsConfident(j))
    }
}
