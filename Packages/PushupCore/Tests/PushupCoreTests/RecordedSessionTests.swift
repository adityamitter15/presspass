import CoreGraphics
import Foundation
import Testing
import PushupCore
import PushupSynth

private let sampleDevice = DeviceInfo(
    model: "iPhone17,2",
    systemVersion: "26.0",
    appVersion: "1.0",
    appBuild: "1",
    poseModel: "pose_landmarker_full",
    cameraPosition: "front",
    featureVersion: PushupFeatureExtractor.featureVersion
)

private let sampleTags = RecordedSession.Tags(
    lighting: .indoorBright,
    distance: .mid,
    clothing: .fitted,
    tempo: .normal,
    variant: .standard,
    cheat: .none
)

private func makeSession(
    kind: RecordedSession.Kind = .set,
    trueReps: Int? = 8,
    frames: [RecordedFrame]
) -> RecordedSession {
    RecordedSession(
        id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
        createdAt: "2026-07-04T09:30:15Z",
        kind: kind,
        trueReps: trueReps,
        poseLabel: nil,
        subject: "S01",
        tags: sampleTags,
        notes: "kitchen floor",
        device: sampleDevice,
        live: LiveResult(reps: 7, rejectedReps: 1, classifier: "heuristic"),
        frames: frames
    )
}

/// 33 landmarks whose values are distinct and recognisable.
private func landmarks(
    x: Float = 0.123456789,
    visibility: Float? = 0.87654321,
    presence: Float? = 0.99999
) -> [RawLandmark] {
    (0..<33).map { index in
        RawLandmark(x: x, y: 0.25 + Float(index) / 100, z: -0.0123456789, visibility: visibility, presence: presence)
    }
}

private func world(x: Float = 0.123456789) -> [RawLandmark] {
    (0..<33).map { _ in RawLandmark(x: x, y: -0.987654321, z: 0.0000049, visibility: nil, presence: nil) }
}

@Suite("RecordedSession")
struct RecordedSessionTests {
    // MARK: - Round trip

    @Test("a session survives JSON and compares equal, with schema 2")
    func roundTrip() throws {
        let raws = [
            RawPoseFrame(timestamp: 10, presentationTime: 500, landmarks: landmarks(), worldLandmarks: world()),
            RawPoseFrame(timestamp: 10.0333, presentationTime: 500.0333, landmarks: nil, worldLandmarks: nil),
            RawPoseFrame(timestamp: 10.0667, presentationTime: nil, landmarks: landmarks(visibility: nil, presence: nil), worldLandmarks: world()),
        ]
        let frames = raws.map {
            RecordedFrame(raw: $0, originTimestamp: 10, originPresentationTime: 500)
        }
        let session = makeSession(frames: frames)

        let decoded = try RecordedSession.decode(session.jsonData())
        #expect(decoded == session)
        #expect(decoded.schema == 2)
        #expect(RecordedSession.currentSchema == 2)
    }

    @Test("write(to:) and load(from:) round trip through a file")
    func fileRoundTrip() throws {
        let session = makeSession(frames: [
            RecordedFrame(
                raw: RawPoseFrame(timestamp: 1, presentationTime: 2, landmarks: landmarks(), worldLandmarks: world()),
                originTimestamp: 1,
                originPresentationTime: 2
            ),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(RecordedSession.fileName(kind: .set, createdAt: session.createdAt, id: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: url) }

        try session.write(to: url)
        #expect(try RecordedSession.load(from: url) == session)
    }

    @Test("a held-pose session keeps its label and omits trueReps")
    func poseSession() throws {
        var session = makeSession(kind: .pose, trueReps: nil, frames: [])
        session.poseLabel = .notPushup
        let data = try session.jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"poseLabel\":\"not_pushup\""))
        #expect(!text.contains("trueReps"))
        #expect(try RecordedSession.decode(data) == session)
    }

    // MARK: - Rounding

    @Test("values are stored at the stated precision and t of the first frame is 0")
    func rounding() throws {
        let raw = RawPoseFrame(
            timestamp: 100.123456789,
            presentationTime: 7000.987654321,
            landmarks: landmarks(),
            worldLandmarks: world()
        )
        let first = RecordedFrame(raw: raw, originTimestamp: 100.123456789, originPresentationTime: 7000.987654321)
        #expect(first.t == 0)
        #expect(first.pts == 0)

        let later = RecordedFrame(
            raw: RawPoseFrame(timestamp: 100.123456789 + 0.0333333333, presentationTime: 7000.987654321 + 0.0333333333, landmarks: landmarks(), worldLandmarks: world()),
            originTimestamp: 100.123456789,
            originPresentationTime: 7000.987654321
        )
        #expect(later.t == 0.033333)
        #expect(later.pts == 0.033333)

        let lm = try #require(first.lm)
        let wlm = try #require(first.wlm)
        #expect(lm.count == 165)
        #expect(wlm.count == 99)
        // Landmark 0: x, y, z at 6 decimals, visibility and presence at 4.
        #expect(lm[0] == 0.123457)
        #expect(lm[1] == 0.25)
        #expect(lm[2] == -0.012346)
        #expect(lm[3] == 0.8765)
        #expect(lm[4] == 1.0)
        // Landmark 32 starts at index 160.
        #expect(lm[161] == 0.57)
        // World: 5 decimals.
        #expect(wlm[0] == 0.12346)
        #expect(wlm[1] == -0.98765)
        #expect(wlm[2] == 0.00000)

        // The JSON prints the short form, not Float noise.
        let text = try #require(String(data: makeSession(frames: [first]).jsonData(), encoding: .utf8))
        #expect(text.contains("0.123457,0.25,-0.012346,0.8765,1"))
        #expect(!text.contains("0.1234567"))
    }

    @Test("negative zero is stored as zero")
    func negativeZero() throws {
        let tiny = (0..<33).map { _ in RawLandmark(x: -0.0000001, y: 0, z: 0, visibility: 1, presence: 1) }
        let frame = RecordedFrame(
            raw: RawPoseFrame(timestamp: 0, presentationTime: nil, landmarks: tiny, worldLandmarks: nil),
            originTimestamp: 0,
            originPresentationTime: nil
        )
        let lm = try #require(frame.lm)
        #expect(lm[0].sign == .plus)
    }

    @Test("an unknown presentation time gives a nil pts")
    func unknownPresentationTime() {
        let noPTS = RecordedFrame(
            raw: RawPoseFrame(timestamp: 1, presentationTime: nil, landmarks: nil, worldLandmarks: nil),
            originTimestamp: 0,
            originPresentationTime: 5
        )
        #expect(noPTS.pts == nil)
        let noOrigin = RecordedFrame(
            raw: RawPoseFrame(timestamp: 1, presentationTime: 6, landmarks: nil, worldLandmarks: nil),
            originTimestamp: 0,
            originPresentationTime: nil
        )
        #expect(noOrigin.pts == nil)
    }

    // MARK: - Sentinel

    @Test("nil visibility and presence encode as -1 and decode back to nil")
    func sentinel() throws {
        let raw = RawPoseFrame(
            timestamp: 0,
            presentationTime: nil,
            landmarks: landmarks(visibility: nil, presence: 0.5),
            worldLandmarks: nil
        )
        let frame = RecordedFrame(raw: raw, originTimestamp: 0, originPresentationTime: nil)
        let lm = try #require(frame.lm)
        #expect(lm[3] == RecordedFrame.missingValue)
        #expect(lm[3] == -1)
        #expect(lm[4] == 0.5)

        let decoded = try JSONDecoder().decode(RecordedFrame.self, from: JSONEncoder().encode(frame))
        let back = try #require(decoded.rawPoseFrame.landmarks)
        #expect(back.allSatisfy { $0.visibility == nil })
        #expect(back.allSatisfy { $0.presence == 0.5 })
    }

    @Test("world landmarks come back with nil visibility and presence")
    func worldLandmarksHaveNoScores() throws {
        let frame = RecordedFrame(
            raw: RawPoseFrame(timestamp: 0, presentationTime: nil, landmarks: nil, worldLandmarks: world()),
            originTimestamp: 0,
            originPresentationTime: nil
        )
        let back = try #require(frame.rawPoseFrame.worldLandmarks)
        #expect(back.count == 33)
        #expect(back.allSatisfy { $0.visibility == nil && $0.presence == nil })
    }

    // MARK: - Malformed frames

    @Test("wrong-length lm or wlm decode to nil landmarks instead of crashing")
    func malformedFrames() {
        for count in [0, 1, 164, 166, 330] {
            let frame = RecordedFrame(t: 0, pts: nil, lm: [Double](repeating: 0.5, count: count), wlm: nil)
            #expect(frame.rawPoseFrame.landmarks == nil, "lm count \(count)")
        }
        for count in [0, 1, 98, 100, 165] {
            let frame = RecordedFrame(t: 0, pts: nil, lm: nil, wlm: [Double](repeating: 0.5, count: count))
            #expect(frame.rawPoseFrame.worldLandmarks == nil, "wlm count \(count)")
        }
    }

    @Test("a wrong-length landmark array is stored as absent rather than as a short array")
    func wrongLengthInputStoredAbsent() {
        let frame = RecordedFrame(
            raw: RawPoseFrame(timestamp: 0, presentationTime: nil, landmarks: Array(landmarks().prefix(10)), worldLandmarks: Array(world().prefix(10))),
            originTimestamp: 0,
            originPresentationTime: nil
        )
        #expect(frame.lm == nil)
        #expect(frame.wlm == nil)
    }

    @Test("a non-finite landmark value is stored as absent so the file can still be written")
    func nonFiniteStoredAbsent() throws {
        var bad = landmarks()
        bad[3] = RawLandmark(x: .nan, y: 0, z: 0, visibility: 1, presence: 1)
        let frame = RecordedFrame(
            raw: RawPoseFrame(timestamp: 0, presentationTime: nil, landmarks: bad, worldLandmarks: nil),
            originTimestamp: 0,
            originPresentationTime: nil
        )
        #expect(frame.lm == nil)
        _ = try makeSession(frames: [frame]).jsonData()
    }

    @Test("a no-body frame maps to a PoseFrame with no joints")
    func noBodyFrame() {
        let session = makeSession(frames: [RecordedFrame(t: 1.5, pts: nil, lm: nil, wlm: nil)])
        let poseFrames = session.poseFrames()
        #expect(poseFrames.count == 1)
        #expect(poseFrames[0].joints.isEmpty)
        #expect(poseFrames[0].timestamp == 1.5)
    }

    // MARK: - Schema and field names

    @Test("a file with another schema number throws unsupportedSchema")
    func unsupportedSchema() throws {
        for schema in [1, 3, 0] {
            var session = makeSession(frames: [])
            session.schema = schema
            let data = try session.jsonData()
            #expect(throws: RecordedSessionError.unsupportedSchema(schema)) {
                try RecordedSession.decode(data)
            }
        }
    }

    @Test("a schema 1 style file without session fields reports its schema number")
    func oldFormatReportsSchema() {
        let data = Data(#"{"label": "up", "source": "x", "frames": []}"#.utf8)
        #expect(throws: DecodingError.self) { try RecordedSession.decode(data) }
        let v1 = Data(#"{"schema": 1, "frames": []}"#.utf8)
        #expect(throws: RecordedSessionError.unsupportedSchema(1)) { try RecordedSession.decode(v1) }
    }

    @Test("a hand-written minimal JSON document decodes, proving the on-disk field names")
    func handWrittenJSON() throws {
        let json = """
        {
          "schema": 2,
          "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
          "createdAt": "2026-07-04T09:30:15Z",
          "kind": "set",
          "trueReps": 12,
          "subject": "S07",
          "tags": {
            "lighting": "indoor_bright",
            "distance": "far",
            "clothing": "loose",
            "tempo": "fast",
            "variant": "knee",
            "cheat": "half_reps"
          },
          "notes": "second take",
          "device": {
            "model": "iPhone17,2",
            "systemVersion": "26.0",
            "appVersion": "1.0",
            "appBuild": "42",
            "poseModel": "pose_landmarker_full",
            "cameraPosition": "front",
            "featureVersion": "v1"
          },
          "live": { "reps": 11, "rejectedReps": 2, "classifier": "coreml" },
          "frames": [
            { "t": 0, "pts": 0, "lm": null },
            { "t": 0.033333 }
          ]
        }
        """
        let session = try RecordedSession.decode(Data(json.utf8))
        #expect(session.schema == 2)
        #expect(session.kind == .set)
        #expect(session.trueReps == 12)
        #expect(session.poseLabel == nil)
        #expect(session.subject == "S07")
        #expect(session.tags == RecordedSession.Tags(lighting: .indoorBright, distance: .far, clothing: .loose, tempo: .fast, variant: .knee, cheat: .halfReps))
        #expect(session.notes == "second take")
        #expect(session.device.model == "iPhone17,2")
        #expect(session.device.appBuild == "42")
        #expect(session.device.featureVersion == "v1")
        #expect(session.live == LiveResult(reps: 11, rejectedReps: 2, classifier: "coreml"))
        #expect(session.frames.count == 2)
        #expect(session.frames[0].pts == 0)
        #expect(session.frames[1].t == 0.033333)
        #expect(session.frames[1].lm == nil)
        #expect(session.frames[1].wlm == nil)
    }

    @Test("tag raw values are exactly the documented strings")
    func tagRawValues() {
        typealias T = RecordedSession.Tags
        #expect(T.Lighting.allCases.map(\.rawValue) == ["daylight", "indoor_bright", "dim"])
        #expect(T.Distance.allCases.map(\.rawValue) == ["near", "mid", "far"])
        #expect(T.Clothing.allCases.map(\.rawValue) == ["fitted", "loose"])
        #expect(T.Tempo.allCases.map(\.rawValue) == ["slow", "normal", "fast", "na"])
        #expect(T.Variant.allCases.map(\.rawValue) == ["standard", "knuckle", "knee", "wide", "narrow", "na"])
        #expect(T.Cheat.allCases.map(\.rawValue) == ["none", "half_reps", "arm_wave", "phone_moved", "video_replay", "other"])
        #expect(RecordedSession.Kind.allCases.map(\.rawValue) == ["set", "negative", "pose"])
    }

    // MARK: - File names

    @Test("file names follow kind_yyyyMMdd-HHmmss_idprefix.json in UTC")
    func fileNamePattern() {
        let name = RecordedSession.fileName(
            kind: .negative,
            createdAt: "2026-07-04T09:30:15Z",
            id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        )
        #expect(name == "negative_20260704-093015_3f2504e0.json")

        // An offset timestamp is normalised to UTC.
        let offset = RecordedSession.fileName(kind: .set, createdAt: "2026-07-04T23:30:15+02:00", id: "ABCDEF12-0000-0000-0000-000000000000")
        #expect(offset == "set_20260704-213015_abcdef12.json")

        let fromDate = RecordedSession.fileName(kind: .pose, createdAt: Date(timeIntervalSince1970: 0), id: "ABCDEF12-0000-0000-0000-000000000000")
        #expect(fromDate == "pose_19700101-000000_abcdef12.json")
    }

    @Test("iso8601String produces a UTC string the file name helper can read back")
    func iso8601Helper() {
        let date = Date(timeIntervalSince1970: 1_783_157_415)
        let string = RecordedSession.iso8601String(from: date)
        #expect(string.hasSuffix("Z"))
        #expect(RecordedSession.fileName(kind: .set, createdAt: string, id: "00000000")
            == RecordedSession.fileName(kind: .set, createdAt: date, id: "00000000"))
    }

    @Test("isRecordingFileName accepts generated names for every kind")
    func acceptsGeneratedNames() {
        for kind in RecordedSession.Kind.allCases {
            let name = RecordedSession.fileName(kind: kind, createdAt: "2026-07-04T09:30:15Z", id: UUID().uuidString)
            #expect(RecordedSession.isRecordingFileName(name), "\(name)")
        }
    }

    @Test("isRecordingFileName rejects everything else", arguments: [
        "notes.json",
        "set_2026.json",
        "set_20260704-093015_3f2504e0.txt",
        "set_20260704-093015_3F2504E0.json",
        "set_20260704-093015_3f2504e.json",
        "set_20260704-093015_3f2504e00.json",
        "up_20260704-093015_3f2504e0.json",
        "../set_20260704-093015_3f2504e0.json",
        "sub/set_20260704-093015_3f2504e0.json",
        "/etc/set_20260704-093015_3f2504e0.json",
        " set_20260704-093015_3f2504e0.json",
        "set_20260704-093015_3f2504e0.json\n",
        "set_20260704-093015_3f2504e0.json.json",
        "",
    ])
    func rejectsOtherNames(_ name: String) {
        #expect(!RecordedSession.isRecordingFileName(name))
    }

    // MARK: - Replay equivalence

    @Test("a replayed recording counts the same reps and rejections as the live pipeline")
    func replayEquivalence() throws {
        let poseFrames = SyntheticPose.repSequence(reps: 8, secondsPerRep: 2.0, startTime: 12.5)
        let raws = SyntheticPose.rawFrames(from: poseFrames)

        // Live: the pipeline sees the mapped raw frames directly.
        let live = PushupPipeline(classifier: HeuristicPoseClassifier())
        var liveOutput: PipelineOutput?
        for raw in raws { liveOutput = live.process(BlazePoseMapping.poseFrame(from: raw)) }
        let liveFinal = try #require(liveOutput)
        #expect(liveFinal.reps == 8)

        // Recorded: encode, serialise, load, map, replay on a fresh pipeline.
        let origin = try #require(raws.first)
        let frames = raws.map {
            RecordedFrame(raw: $0, originTimestamp: origin.timestamp, originPresentationTime: origin.presentationTime)
        }
        #expect(frames.first?.t == 0)
        let session = makeSession(trueReps: 8, frames: frames)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try session.write(to: url)
        let loaded = try RecordedSession.load(from: url)
        #expect(loaded == session)

        let replay = PushupPipeline(classifier: HeuristicPoseClassifier())
        var replayOutput: PipelineOutput?
        for frame in loaded.poseFrames() { replayOutput = replay.process(frame) }
        let replayFinal = try #require(replayOutput)

        #expect(replayFinal.reps == 8)
        #expect(replayFinal.rejectedReps == liveFinal.rejectedReps)
    }

    // MARK: - Synthetic landmark helper

    @Test("the synthetic landmark helper inverts the BlazePose mapping")
    func rawLandmarkHelperInvertsMapping() throws {
        var options = SyntheticPose.Options()
        options.dropped = [.leftWrist]
        let joints = SyntheticPose.joints(elbowDegrees: 120, options)
        let mapped = BlazePoseMapping.poseFrame(timestamp: 0, landmarks: SyntheticPose.rawLandmarks(from: joints))

        #expect(Set(mapped.joints.keys) == Set(joints.keys))
        #expect(mapped.joints[.leftWrist] == nil)
        for (name, original) in joints {
            let point = try #require(mapped.joints[name], "\(name)")
            #expect(abs(point.x - original.x) < 1e-6, "\(name) x")
            #expect(abs(point.y - original.y) < 1e-6, "\(name) y")
            #expect(point.confidence == original.confidence, "\(name) confidence")
        }
    }

    // MARK: - Motion

    private func sampleMotion() -> MotionStream {
        var motion = MotionStream(rateHz: 100)
        motion.append(t: 0.01, userAcceleration: (0.001, -0.002, 0.003), rotationRate: (0.1, 0.2, -0.3), gravity: (0, -0.5, -0.866))
        motion.append(t: 0.02, userAcceleration: (0.004, -0.005, 0.006), rotationRate: (0.4, 0.5, -0.6), gravity: (0, -0.5, -0.866))
        return motion
    }

    @Test("a session with motion survives JSON and compares equal")
    func motionRoundTrip() throws {
        var session = makeSession(frames: [])
        session.motion = sampleMotion()

        let data = try session.jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"motion\""))
        #expect(text.contains("\"rateHz\":100"))

        let decoded = try RecordedSession.decode(data)
        #expect(decoded == session)
        #expect(decoded.schema == 2)
        #expect(decoded.motion?.sampleCount == 2)
    }

    @Test("a file without motion decodes with motion nil, and nil motion is not written")
    func motionAbsent() throws {
        let session = makeSession(frames: [])
        #expect(session.motion == nil)

        let data = try session.jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("motion"))
        #expect(try RecordedSession.decode(data).motion == nil)
    }

    @Test("motion values are stored at the stated precision")
    func motionRounding() throws {
        var motion = MotionStream(rateHz: 100)
        motion.append(
            t: 12345.123456789,
            userAcceleration: (0.123456789, -0.0000001, 1.0000049),
            rotationRate: (-0.987654321, 0, 2.5),
            gravity: (0.0000049, -0.0000051, -0.99999999)
        )
        let sample = try #require(motion.sample(at: 0))
        #expect(sample.t == 12345.123457)
        #expect(sample.userAcceleration.x == 0.12346)
        #expect(sample.userAcceleration.y == 0)
        #expect(sample.userAcceleration.y.sign == .plus)
        #expect(sample.userAcceleration.z == 1.0)
        #expect(sample.rotationRate.x == -0.98765)
        #expect(sample.rotationRate.z == 2.5)
        #expect(sample.gravity.x == 0)
        #expect(sample.gravity.y == -0.00001)
        #expect(sample.gravity.z == -1.0)
    }

    @Test("a sample with a non-finite value is dropped")
    func motionNonFinite() {
        var motion = MotionStream(rateHz: 100)
        motion.append(t: 0, userAcceleration: (.nan, 0, 0), rotationRate: (0, 0, 0), gravity: (0, 0, 0))
        motion.append(t: 0, userAcceleration: (0, 0, 0), rotationRate: (.infinity, 0, 0), gravity: (0, 0, 0))
        #expect(motion.sampleCount == 0)
        #expect(motion.samples.isEmpty)
    }

    @Test("sampleCount and sample(at:) read the flat layout")
    func motionAccessors() throws {
        let motion = sampleMotion()
        #expect(MotionStream.stride == 10)
        #expect(motion.samples.count == 20)
        #expect(motion.sampleCount == 2)

        let second = try #require(motion.sample(at: 1))
        #expect(second.t == 0.02)
        #expect(second.userAcceleration == (0.004, -0.005, 0.006))
        #expect(second.rotationRate == (0.4, 0.5, -0.6))
        #expect(second.gravity == (0, -0.5, -0.866))

        #expect(motion.sample(at: 2) == nil)
        #expect(motion.sample(at: -1) == nil)
    }

    @Test("a ragged samples array counts whole samples only")
    func motionRagged() throws {
        // 2 whole samples and 4 stray values, as a truncated file might hold.
        let motion = MotionStream(rateHz: 100, samples: Array(repeating: 0.5, count: 24))
        #expect(motion.sampleCount == 2)
        #expect(motion.sample(at: 1) != nil)
        #expect(motion.sample(at: 2) == nil)
        #expect(MotionStream(rateHz: 100, samples: Array(repeating: 0.5, count: 9)).sampleCount == 0)
        #expect(MotionStream(rateHz: 100, samples: Array(repeating: 0.5, count: 9)).sample(at: 0) == nil)
    }

    // MARK: - Video

    private func sampleVideo() -> VideoInfo {
        VideoInfo(
            file: "set_20260704-093015_3f2504e0.mp4",
            width: 720,
            height: 1280,
            codec: "h264",
            frameCount: 912,
            startPts: -0.0333
        )
    }

    @Test("a session with video info survives JSON and compares equal")
    func videoRoundTrip() throws {
        var session = makeSession(frames: [])
        session.video = sampleVideo()

        let data = try session.jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"video\""))
        #expect(text.contains("\"file\":\"set_20260704-093015_3f2504e0.mp4\""))
        #expect(text.contains("\"codec\":\"h264\""))

        let decoded = try RecordedSession.decode(data)
        #expect(decoded == session)
        #expect(decoded.schema == 2)
        #expect(decoded.video == sampleVideo())
        #expect(decoded.video?.frameCount == 912)
    }

    @Test("the memberwise initialiser takes video last and defaults it to nil")
    func videoInitialiser() {
        let with = RecordedSession(
            id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            createdAt: "2026-07-04T09:30:15Z",
            kind: .set,
            trueReps: 1,
            poseLabel: nil,
            subject: "S01",
            tags: sampleTags,
            notes: "",
            device: sampleDevice,
            live: nil,
            frames: [],
            motion: nil,
            video: sampleVideo()
        )
        #expect(with.video == sampleVideo())
        #expect(makeSession(frames: []).video == nil)
    }

    @Test("a file without video decodes with video nil, and nil video is not written")
    func videoAbsent() throws {
        let session = makeSession(frames: [])
        #expect(session.video == nil)

        let data = try session.jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("video"))
        #expect(try RecordedSession.decode(data).video == nil)

        // A hand-written file that never mentions video, with null also accepted.
        let minimal = Data(#"""
        {"schema":2,"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","createdAt":"2026-07-04T09:30:15Z",
         "kind":"negative","trueReps":0,"subject":"S01",
         "tags":{"lighting":"dim","distance":"far","clothing":"loose","tempo":"na","variant":"na","cheat":"none"},
         "notes":"","device":{"model":"m","systemVersion":"26","appVersion":"1","appBuild":"1","poseModel":"p","cameraPosition":"front","featureVersion":"v1"},
         "frames":[],"video":null}
        """#.utf8)
        #expect(try RecordedSession.decode(minimal).video == nil)
    }

    @Test("a hand-written video object decodes, proving the on-disk field names")
    func videoFieldNames() throws {
        let json = Data(#"""
        {"file":"pose_20260704-093015_3f2504e0.mp4","width":540,"height":960,"codec":"h264","frameCount":450,"startPts":0.0667}
        """#.utf8)
        let info = try JSONDecoder().decode(VideoInfo.self, from: json)
        #expect(info == VideoInfo(file: "pose_20260704-093015_3f2504e0.mp4", width: 540, height: 960, codec: "h264", frameCount: 450, startPts: 0.0667))
    }

    @Test("startPts is rounded to 6 decimals and survives JSON unchanged", arguments: [
        (12.3456789, 12.345679),
        (-0.0333333333, -0.033333),
        (0.0000004, 0.0),
        (-0.0000001, 0.0),
        (-1234.5678904, -1234.56789),
    ])
    func startPtsRounding(input: Double, expected: Double) throws {
        let info = VideoInfo(file: "x.mp4", width: 2, height: 2, codec: "h264", frameCount: 1, startPts: input)
        #expect(info.startPts == expected)
        #expect(info.startPts.sign == (expected < 0 ? .minus : .plus))

        var session = makeSession(frames: [])
        session.video = info
        let decoded = try RecordedSession.decode(session.jsonData())
        #expect(decoded.video?.startPts == expected)
    }

    @Test("videoFileName swaps the json extension for mp4")
    func videoFileNames() {
        #expect(RecordedSession.videoFileName(forSessionFileName: "set_20260704-093015_3f2504e0.json")
            == "set_20260704-093015_3f2504e0.mp4")

        for kind in RecordedSession.Kind.allCases {
            let json = RecordedSession.fileName(kind: kind, createdAt: "2026-07-04T09:30:15Z", id: UUID().uuidString)
            let video = RecordedSession.videoFileName(forSessionFileName: json)
            #expect(video.hasSuffix(".mp4"))
            #expect(!video.contains("json"))
            #expect(RecordedSession.isRecordingVideoFileName(video), "\(video)")
            #expect(!RecordedSession.isRecordingFileName(video), "\(video)")
            #expect(RecordedSession.isRecordingFileName(json))
            #expect(!RecordedSession.isRecordingVideoFileName(json))
        }

        // Only a trailing suffix is replaced.
        #expect(RecordedSession.videoFileName(forSessionFileName: "a.json.json") == "a.json.mp4")
        #expect(RecordedSession.videoFileName(forSessionFileName: "notes") == "notes.mp4")
    }

    @Test("isRecordingVideoFileName rejects everything else", arguments: [
        "notes.mp4",
        "set_2026.mp4",
        "set_20260704-093015_3f2504e0.mov",
        "set_20260704-093015_3f2504e0.json",
        "set_20260704-093015_3F2504E0.mp4",
        "set_20260704-093015_3f2504e.mp4",
        "set_20260704-093015_3f2504e00.mp4",
        "up_20260704-093015_3f2504e0.mp4",
        "../set_20260704-093015_3f2504e0.mp4",
        "sub/set_20260704-093015_3f2504e0.mp4",
        "/etc/set_20260704-093015_3f2504e0.mp4",
        " set_20260704-093015_3f2504e0.mp4",
        "set_20260704-093015_3f2504e0.mp4\n",
        "set_20260704-093015_3f2504e0.mp4.mp4",
        "",
    ])
    func rejectsOtherVideoNames(_ name: String) {
        #expect(!RecordedSession.isRecordingVideoFileName(name))
    }

    // MARK: - Size

    @Test("a 30 fps session stays well under the size budget")
    func encodedSize() throws {
        let poseFrames = SyntheticPose.repSequence(reps: 28, secondsPerRep: 2.0, leadInSeconds: 2, leadOutSeconds: 2)
        let raws = SyntheticPose.rawFrames(from: poseFrames).prefix(60 * 30)
        let origin = try #require(raws.first)
        let frames = raws.map {
            RecordedFrame(raw: $0, originTimestamp: origin.timestamp, originPresentationTime: origin.presentationTime)
        }
        let bytes = try makeSession(frames: frames).jsonData().count
        let bytesPerSecond = Double(bytes) / Double(frames.count) * 30
        // Measured about 46 kB per second for this synthetic data and about
        // 67 kB per second for full-precision random values (the worst
        // case), so this is a regression guard, not a target.
        #expect(bytesPerSecond < 80_000)
    }
}
