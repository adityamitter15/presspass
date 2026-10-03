import CoreGraphics
import Foundation
import Testing
import PushupCore

@Suite("BlazePoseMapping")
struct BlazePoseMappingTests {
    /// 33 landmarks, all visible at the image centre unless overridden.
    private func landmarks(
        count: Int = 33,
        overrides: [Int: RawLandmark] = [:]
    ) -> [RawLandmark] {
        (0..<count).map { index in
            overrides[index] ?? RawLandmark(x: 0.5, y: 0.5, z: 0, visibility: 0.9, presence: 0.9)
        }
    }

    private func landmark(x: Float, y: Float, visibility: Float?) -> RawLandmark {
        RawLandmark(x: x, y: y, z: 0, visibility: visibility, presence: 1)
    }

    private static let indexTable: [(JointName, Int)] = [
        (.nose, 0),
        (.leftShoulder, 11), (.rightShoulder, 12),
        (.leftElbow, 13), (.rightElbow, 14),
        (.leftWrist, 15), (.rightWrist, 16),
        (.leftHip, 23), (.rightHip, 24),
        (.leftKnee, 25), (.rightKnee, 26),
        (.leftAnkle, 27), (.rightAnkle, 28),
    ]

    @Test("each joint reads from its BlazePose landmark index", arguments: indexTable)
    func indexTable(_ entry: (JointName, Int)) throws {
        let (name, index) = entry
        // Give every landmark a distinct x so a wrong index is visible.
        let all = (0..<33).map { i in
            RawLandmark(x: Float(i) / 64, y: 0.5, z: 0, visibility: 0.9, presence: 0.9)
        }
        let frame = BlazePoseMapping.poseFrame(timestamp: 0, landmarks: all)
        let point = try #require(frame.joints[name])
        #expect(point.x == CGFloat(Float(index) / 64))
    }

    @Test("a full pose maps exactly the 13 detected joints plus neck and root")
    func fullPoseJointSet() {
        let frame = BlazePoseMapping.poseFrame(timestamp: 0, landmarks: landmarks())
        #expect(Set(frame.joints.keys) == Set(JointName.allCases))
        #expect(frame.joints.count == 15)
    }

    @Test("the timestamp is passed through")
    func timestampPassedThrough() {
        let frame = BlazePoseMapping.poseFrame(timestamp: 12.5, landmarks: landmarks())
        #expect(frame.timestamp == 12.5)
    }

    @Test("y is flipped into the bottom-left origin convention")
    func yIsFlipped() throws {
        let frame = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [
                0: landmark(x: 0.25, y: 0.25, visibility: 0.9),
                27: landmark(x: 0.75, y: 1.0, visibility: 0.9),
                28: landmark(x: 0.75, y: 0.0, visibility: 0.9),
            ])
        )
        let nose = try #require(frame.joints[.nose])
        #expect(nose.x == 0.25)
        #expect(nose.y == 0.75)
        #expect(try #require(frame.joints[.leftAnkle]).y == 0.0)
        #expect(try #require(frame.joints[.rightAnkle]).y == 1.0)
    }

    @Test("neck and root are midpoints with the minimum of the parents' confidence")
    func neckAndRootAreMidpoints() throws {
        let frame = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [
                11: landmark(x: 0.25, y: 0.25, visibility: 0.5),
                12: landmark(x: 0.75, y: 0.25, visibility: 0.75),
                23: landmark(x: 0.5, y: 0.75, visibility: 1.0),
                24: landmark(x: 0.75, y: 0.75, visibility: 0.25),
            ])
        )
        let neck = try #require(frame.joints[.neck])
        #expect(neck.x == 0.5)
        #expect(neck.y == 0.75)
        #expect(neck.confidence == 0.5)

        let root = try #require(frame.joints[.root])
        #expect(root.x == 0.625)
        #expect(root.y == 0.25)
        #expect(root.confidence == 0.25)
    }

    @Test("a landmark with visibility below 0.1 is omitted")
    func lowVisibilityOmitted() {
        let frame = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [
                15: landmark(x: 0.3, y: 0.3, visibility: 0.05),
                16: landmark(x: 0.3, y: 0.3, visibility: 0.099),
            ])
        )
        #expect(frame.joints[.leftWrist] == nil)
        #expect(frame.joints[.rightWrist] == nil)
        #expect(frame.joints[.leftElbow] != nil)
    }

    @Test("visibility exactly 0.1 is kept")
    func visibilityAtThresholdKept() throws {
        let frame = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [15: landmark(x: 0.3, y: 0.3, visibility: 0.1)])
        )
        #expect(try #require(frame.joints[.leftWrist]).confidence == 0.1)
    }

    @Test("nil visibility becomes a confidence of 0.5")
    func nilVisibilityIsHalf() throws {
        let frame = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [15: landmark(x: 0.3, y: 0.3, visibility: nil)])
        )
        #expect(try #require(frame.joints[.leftWrist]).confidence == 0.5)
    }

    @Test("visibility above 1 clamps to 1")
    func visibilityClampedToOne() throws {
        let frame = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [15: landmark(x: 0.3, y: 0.3, visibility: 1.5)])
        )
        #expect(try #require(frame.joints[.leftWrist]).confidence == 1.0)
    }

    @Test("negative visibility clamps to 0 and so is omitted")
    func negativeVisibilityOmitted() {
        let frame = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [15: landmark(x: 0.3, y: 0.3, visibility: -0.5)])
        )
        #expect(frame.joints[.leftWrist] == nil)
    }

    @Test("fewer than 29 landmarks gives an empty frame", arguments: [0, 1, 11, 28])
    func shortLandmarkListIsEmpty(_ count: Int) {
        let frame = BlazePoseMapping.poseFrame(timestamp: 3, landmarks: landmarks(count: count))
        #expect(frame.joints.isEmpty)
        #expect(frame.timestamp == 3)
    }

    @Test("exactly 29 landmarks is enough, since the highest index used is 28")
    func twentyNineLandmarksIsEnough() {
        let frame = BlazePoseMapping.poseFrame(timestamp: 0, landmarks: landmarks(count: 29))
        #expect(frame.joints.count == 15)
    }

    @Test("an omitted shoulder means no neck")
    func omittedShoulderMeansNoNeck() {
        for index in [11, 12] {
            let frame = BlazePoseMapping.poseFrame(
                timestamp: 0,
                landmarks: landmarks(overrides: [index: landmark(x: 0.3, y: 0.3, visibility: 0.0)])
            )
            #expect(frame.joints[.neck] == nil)
            #expect(frame.joints[.root] != nil)
        }
    }

    @Test("an omitted hip means no root")
    func omittedHipMeansNoRoot() {
        for index in [23, 24] {
            let frame = BlazePoseMapping.poseFrame(
                timestamp: 0,
                landmarks: landmarks(overrides: [index: landmark(x: 0.3, y: 0.3, visibility: 0.0)])
            )
            #expect(frame.joints[.root] == nil)
            #expect(frame.joints[.neck] != nil)
        }
    }

    @Test("presence and z do not affect the mapping")
    func presenceAndDepthIgnored() throws {
        let a = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [15: RawLandmark(x: 0.3, y: 0.3, z: 0, visibility: 0.8, presence: 1)])
        )
        let b = BlazePoseMapping.poseFrame(
            timestamp: 0,
            landmarks: landmarks(overrides: [15: RawLandmark(x: 0.3, y: 0.3, z: -2, visibility: 0.8, presence: 0)])
        )
        let pa = try #require(a.joints[.leftWrist])
        let pb = try #require(b.joints[.leftWrist])
        #expect(pa.x == pb.x && pa.y == pb.y && pa.confidence == pb.confidence)
    }

    @Test("RawLandmark round-trips through JSON")
    func rawLandmarkCodable() throws {
        let original = RawLandmark(x: 0.1, y: 0.2, z: 0.3, visibility: nil, presence: 0.4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RawLandmark.self, from: data)
        #expect(decoded == original)
    }
}
