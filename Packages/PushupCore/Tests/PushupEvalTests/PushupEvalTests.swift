import CryptoKit
import Foundation
import Testing
import PushupCore
import PushupSynth
@testable import PushupEval

/// A throwaway directory, removed by the caller with `defer`.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pushup-eval-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func replay(_ session: RecordedSession, config: PipelineConfig = .default) -> SessionResult {
    Replay.replay(session, file: "test.json", pipeline: config.makePipeline())
}

@Suite("Synthetic sessions replay to their ground truth")
struct ReplayCountTests {
    @Test("clean sets replay to exactly trueReps", arguments: [
        (3, RecordedSession.Tags.Tempo.normal),
        (8, .normal),
        (12, .slow),
        (6, .fast),
        (15, .slow),
    ])
    func cleanSets(reps: Int, tempo: RecordedSession.Tags.Tempo) throws {
        let session = SyntheticSessions.cleanSet(reps: reps, tempo: tempo)
        #expect(session.trueReps == reps)
        #expect(replay(session).predictedReps == reps)
    }

    @Test("clean sets are exact for several seeds", arguments: [1, 2, 3, 4, 5, 99] as [UInt64])
    func seeds(seed: UInt64) {
        let session = SyntheticSessions.cleanSet(reps: 7, tempo: .fast, seed: seed)
        #expect(replay(session).predictedReps == 7)
    }

    @Test("half-rep, arm-wave and negative sessions replay to 0")
    func zeroTruthSessions() throws {
        let half = SyntheticSessions.halfRepSet()
        let wave = SyntheticSessions.armWaveSet()
        let negative = SyntheticSessions.negativeClip()
        for session in [half, wave, negative] {
            #expect(session.trueReps == 0)
            #expect(replay(session).predictedReps == 0)
        }
        #expect(negative.kind == .negative)
    }

    @Test("a mixed set counts only its valid reps")
    func mixedSet() {
        let session = SyntheticSessions.mixedSet(validReps: 4, halfReps: 3)
        #expect(session.trueReps == 4)
        #expect(replay(session).predictedReps == 4)
    }

    @Test("every synthetic session is labelled")
    func labelling() {
        for session in SyntheticDataset.sessions() {
            #expect(session.notes == "synthetic")
            #expect(session.subject == "SYN")
        }
    }

    @Test("the synthetic dataset covers the required cases")
    func datasetCoverage() {
        let sessions = SyntheticDataset.sessions()
        #expect(sessions.count == SyntheticDataset.sessionCount)
        let cleanReps = Set(sessions.filter { $0.tags.cheat == .none && $0.kind == .set }.compactMap(\.trueReps))
        #expect(cleanReps.count >= 3)
        let tempos = Set(sessions.filter { $0.kind == .set }.map(\.tags.tempo))
        #expect(tempos.count >= 2)
        #expect(sessions.contains { $0.tags.cheat == .halfReps && $0.trueReps == 0 })
        #expect(sessions.contains { $0.tags.cheat == .armWave })
        #expect(sessions.contains { $0.tags.cheat == .halfReps && ($0.trueReps ?? 0) > 0 })
        #expect(sessions.contains { $0.kind == .negative })
        for session in sessions {
            #expect(replay(session).predictedReps == session.trueReps)
        }
    }
}

@Suite("Replay bookkeeping")
struct ReplayBookkeepingTests {
    @Test("repTimes has one strictly increasing entry per predicted rep")
    func repTimes() {
        let result = replay(SyntheticSessions.cleanSet(reps: 8))
        #expect(result.repTimes.count == result.predictedReps)
        #expect(zip(result.repTimes, result.repTimes.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("frame counts add up to the frame total", arguments: [
        SyntheticSessions.cleanSet(reps: 5, noBodySeconds: 0.5),
        SyntheticSessions.armWaveSet(),
        SyntheticSessions.negativeClip(),
    ])
    func frameCounts(session: RecordedSession) {
        let result = replay(session)
        #expect(result.frameCounts.total == result.frames)
        #expect(result.frames == session.frames.count)
    }

    @Test("buckets reflect what happened to the frames")
    func buckets() {
        let leadIn = replay(SyntheticSessions.cleanSet(reps: 3, noBodySeconds: 0.5))
        #expect(leadIn.frameCounts.noBody > 0)
        let wave = replay(SyntheticSessions.armWaveSet())
        #expect(wave.frameCounts.notInPosture > 0)
        #expect(wave.frameCounts.processed == 0)
    }

    @Test("duration and fps come from the frame times")
    func durationAndFps() {
        let result = replay(SyntheticSessions.cleanSet(reps: 2))
        #expect(abs(result.meanFps - 30) < 0.1)
        #expect(abs(result.durationSeconds - Double(result.frames - 1) / 30) < 0.001)
    }

    @Test("a long minPhaseDuration changes the count")
    func configReachesPipeline() {
        let session = SyntheticSessions.cleanSet(reps: 6)
        var config = PipelineConfig.default
        config.repCounter.minPhaseDuration = 30
        #expect(replay(session).predictedReps == 6)
        #expect(replay(session, config: config).predictedReps != 6)
    }
}

@Suite("Config decoding")
struct ConfigDecodingTests {
    @Test("an empty object is the default config")
    func emptyObject() throws {
        let config = try JSONDecoder().decode(PipelineConfig.self, from: Data("{}".utf8))
        #expect(config == .default)
    }

    @Test("an empty nested object is the default too")
    func emptyNested() throws {
        let json = #"{"repCounter": {}, "heuristic": {}}"#
        #expect(try JSONDecoder().decode(PipelineConfig.self, from: Data(json.utf8)) == .default)
    }

    @Test("one overridden key changes only that key")
    func singleOverride() throws {
        let json = #"{"repCounter": {"minPhaseDuration": 2.5}}"#
        let config = try JSONDecoder().decode(PipelineConfig.self, from: Data(json.utf8))
        var expected = PipelineConfig.default
        expected.repCounter.minPhaseDuration = 2.5
        #expect(config == expected)
        #expect(config.heuristic == .default)
    }

    @Test("a heuristic override decodes alone")
    func heuristicOverride() throws {
        let json = #"{"heuristic": {"downElbowDegrees": 110}}"#
        let config = try JSONDecoder().decode(PipelineConfig.self, from: Data(json.utf8))
        var expected = PipelineConfig.default
        expected.heuristic.downElbowDegrees = 110
        #expect(config == expected)
    }

    @Test("a config survives an encode and decode round trip")
    func roundTrip() throws {
        var config = PipelineConfig.default
        config.repCounter.emaAlpha = 0.5
        config.heuristic.upElbowDegrees = 150
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(PipelineConfig.self, from: data) == config)
    }

    @Test("a config file reaches the replay command")
    func configFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.json")
        try Data(#"{"repCounter": {"minPhaseDuration": 30}}"#.utf8).write(to: path)
        let config = try CLI.loadConfig(path.path)
        #expect(config.repCounter.minPhaseDuration == 30)
        #expect(throws: EvalError.self) { try CLI.loadConfig(dir.appendingPathComponent("missing.json").path) }
    }
}

@Suite("Loading and the replay command")
struct LoadingTests {
    @Test("bad files are skipped and listed, not fatal")
    func skipsBadFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = SyntheticSessions.cleanSet(reps: 3)
        try good.write(to: dir.appendingPathComponent(RecordedSession.fileName(kind: .set, createdAt: good.createdAt, id: good.id)))
        try Data(#"{"schema": 1, "label": "up", "source": "x", "joints": {}}"#.utf8)
            .write(to: dir.appendingPathComponent("old_schema.json"))
        try Data("this is not json".utf8).write(to: dir.appendingPathComponent("garbage.json"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let output = try Replay.run(directory: dir, config: .default, source: .heuristic)
        #expect(output.sessions.count == 1)
        #expect(output.skipped.map(\.file) == ["garbage.json", "old_schema.json"])
        #expect(output.skipped.first { $0.file == "old_schema.json" }?.reason.contains("schema 1") == true)
    }

    @Test("sessions are replayed in file name order")
    func order() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticDataset.write(to: dir)
        let output = try Replay.run(directory: dir, config: .default, source: .heuristic)
        #expect(output.sessions.map(\.file) == output.sessions.map(\.file).sorted())
        #expect(output.sessions.count == SyntheticDataset.sessionCount)
    }

    @Test("a missing directory is a runtime error")
    func missingDirectory() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(throws: EvalError.self) { try Replay.run(directory: url, config: .default, source: .heuristic) }
    }

    @Test("a model that cannot load is a runtime error")
    func badModel() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ClassifierSource.coreML(modelURL: dir.appendingPathComponent("nope.mlmodelc"))
        #expect(throws: EvalError.self) { try Replay.run(directory: dir, config: .default, source: source) }
    }

    @Test("running replay twice gives identical bytes")
    func deterministic() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data")
        try SyntheticDataset.write(to: data)

        var messages: [String] = []
        for name in ["a.json", "b.json"] {
            let code = CLI.main(
                arguments: ["replay", "--data", data.path, "--out", dir.appendingPathComponent(name).path],
                out: { messages.append($0) },
                err: { messages.append($0) }
            )
            #expect(code == 0)
        }
        let first = try Data(contentsOf: dir.appendingPathComponent("a.json"))
        let second = try Data(contentsOf: dir.appendingPathComponent("b.json"))
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("the output carries the pipeline block and the live result")
    func outputShape() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticDataset.write(to: dir)
        let output = try Replay.run(directory: dir, config: .default, source: .heuristic)
        #expect(output.schema == 1)
        #expect(output.tool == "pushup-eval")
        #expect(output.pipeline.classifier == "heuristic")
        #expect(output.pipeline.featureVersion == "v1")
        #expect(output.pipeline.isDefaultConfig)
        #expect(output.sessions.allSatisfy { $0.live?.reps == $0.predictedReps })

        var changed = PipelineConfig.default
        changed.repCounter.emaAlpha = 0.5
        let other = try Replay.run(directory: dir, config: changed, source: .heuristic)
        #expect(!other.pipeline.isDefaultConfig)
    }

    @Test("synth is deterministic for a seed and differs between seeds")
    func synthSeeds() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), c = dir.appendingPathComponent("c")
        let namesA = try SyntheticDataset.write(to: a, seed: 1)
        let namesB = try SyntheticDataset.write(to: b, seed: 1)
        _ = try SyntheticDataset.write(to: c, seed: 2)
        #expect(namesA == namesB)
        for name in namesA {
            #expect(try Data(contentsOf: a.appendingPathComponent(name)) == Data(contentsOf: b.appendingPathComponent(name)))
        }
        #expect(!FileManager.default.fileExists(atPath: c.appendingPathComponent(namesA[0]).path))
    }
}

@Suite("Single synthetic session")
struct SingleSessionTests {
    @Test("clean-8 is one loadable set of 8 reps that the pipeline counts as 8")
    func clean8() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = try SyntheticDataset.writeSession(named: "clean-8", to: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [name])
        let session = try RecordedSession.load(from: dir.appendingPathComponent(name))
        #expect(session.kind == .set)
        #expect(session.trueReps == 8)
        #expect(session.tags.tempo == .normal)
        let pipeline = PipelineConfig.default.makePipeline()
        var last: PipelineOutput?
        for frame in session.poseFrames() { last = pipeline.process(frame) }
        #expect(last?.reps == 8)
        #expect(last?.rejectedReps == 0)
    }

    @Test("an unknown name is a runtime error")
    func unknownName() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: EvalError.self) { try SyntheticDataset.writeSession(named: "nope", to: dir) }
    }
}

@Suite("Features CSV")
struct FeaturesCSVTests {
    private let expectedHeader = "session_id,frame,t,has_features,"
        + (0..<25).map { "f\($0)" }.joined(separator: ",")
        + ",posture_valid,joints_confident,heuristic_label,heuristic_confidence"
        + ",torso_ratio,wrist_motion_ratio,raw_depth,gate_failure,session_phase,session_reps"

    private func loaded(_ sessions: [RecordedSession]) -> [LoadedSession] {
        sessions.enumerated().map { LoadedSession(file: "s\($0.offset).json", session: $0.element) }
    }

    @Test("the header matches the contract exactly")
    func header() {
        #expect(FeaturesCSV.header == expectedHeader)
    }

    @Test("one row per frame across all sessions")
    func rowCount() {
        let sessions = [SyntheticSessions.cleanSet(reps: 2), SyntheticSessions.negativeClip(seconds: 5)]
        let lines = FeaturesCSV.render(sessions: loaded(sessions), config: .default)
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first.map(String.init) == expectedHeader)
        #expect(lines.last == "")
        #expect(lines.count - 2 == sessions.map(\.frames.count).reduce(0, +))
        #expect(lines.dropFirst().dropLast().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 39 })
    }

    @Test("a no-body frame has has_features 0 and empty feature cells")
    func noBodyRow() throws {
        let session = SyntheticSessions.cleanSet(reps: 1, noBodySeconds: 0.5)
        #expect(session.frames[0].lm == nil)
        let lines = FeaturesCSV.render(sessions: loaded([session]), config: .default).split(separator: "\n")
        let cells = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(cells[1] == "0")
        #expect(cells[3] == "0")
        #expect(cells[4...28].allSatisfy { $0.isEmpty })
        #expect(cells[29] == "0")
        #expect(cells[31].isEmpty && cells[32].isEmpty)
        // No body: no ratios, a noBody gate failure, positioning and no reps.
        #expect(cells[33...35].allSatisfy { $0.isEmpty })
        #expect(cells[36] == "noBody" && cells[37] == "positioning" && cells[38] == "0")

        // The first frame with a body has numeric features and a label.
        let withBody = try #require(lines.dropFirst().first { $0.split(separator: ",", omittingEmptySubsequences: false)[3] == "1" })
        let bodyCells = withBody.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(bodyCells[4...28].allSatisfy { Float($0) != nil })
        #expect(["up", "down", "not_pushup"].contains(bodyCells[31]))
    }

    @Test("the features command writes the file")
    func command() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data")
        try SyntheticDataset.write(to: data)
        let out = dir.appendingPathComponent("nested/features.csv")
        let code = CLI.main(arguments: ["features", "--data", data.path, "--out", out.path], out: { _ in }, err: { _ in })
        #expect(code == 0)
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.hasPrefix(expectedHeader + "\n"))
    }
}

@Suite("Argument parsing")
struct ArgumentParsingTests {
    @Test("valid command lines parse")
    func valid() {
        #expect(CLI.parse(["replay", "--data", "d", "--out", "o.json"])
            == .success(.replay(data: "d", out: "o.json", config: nil, model: nil, mode: .raw, sessionConfig: nil)))
        #expect(CLI.parse(["replay", "--out=o.json", "--data=d", "--config", "c.json", "--model", "m.mlmodelc"])
            == .success(.replay(data: "d", out: "o.json", config: "c.json", model: "m.mlmodelc", mode: .raw, sessionConfig: nil)))
        #expect(CLI.parse(["replay", "--data", "d", "--out", "o.json", "--mode", "raw"])
            == .success(.replay(data: "d", out: "o.json", config: nil, model: nil, mode: .raw, sessionConfig: nil)))
        #expect(CLI.parse(["replay", "--data", "d", "--out", "o.json", "--mode", "session", "--session-config", "s.json"])
            == .success(.replay(data: "d", out: "o.json", config: nil, model: nil, mode: .session, sessionConfig: "s.json")))
        #expect(CLI.parse(["features", "--data", "d", "--out", "f.csv"])
            == .success(.features(data: "d", out: "f.csv", config: nil, sessionConfig: nil)))
        #expect(CLI.parse(["features", "--data", "d", "--out", "f.csv", "--session-config", "s.json"])
            == .success(.features(data: "d", out: "f.csv", config: nil, sessionConfig: "s.json")))
        #expect(CLI.parse(["synth", "--out", "s"]) == .success(.synth(out: "s", seed: 1)))
        #expect(CLI.parse(["synth", "--out", "s", "--seed", "7"]) == .success(.synth(out: "s", seed: 7)))
        #expect(CLI.parse(["synth", "--out", "s", "--only", "clean-8"]) == .success(.synthOne(name: "clean-8", out: "s", seed: 1)))
        #expect(CLI.parse(["synth", "--only=clean-8", "--out", "s", "--seed", "3"]) == .success(.synthOne(name: "clean-8", out: "s", seed: 3)))
        #expect(CLI.parse(["--help"]) == .success(.help))
    }

    @Test("usage errors", arguments: [
        [],
        ["bogus"],
        ["replay"],
        ["replay", "--data", "d"],
        ["replay", "--out", "o"],
        ["replay", "--data", "d", "--out"],
        ["replay", "--data", "d", "--out", "o", "--nope", "x"],
        ["replay", "--data", "d", "--data", "e", "--out", "o"],
        ["replay", "--data", "d", "--out", "o", "stray"],
        ["replay", "--data", "d", "--out", "o", "--mode", "fast"],
        ["replay", "--data", "d", "--out", "o", "--session-config", "s.json"],
        ["replay", "--data", "d", "--out", "o", "--mode", "raw", "--session-config", "s.json"],
        ["features", "--data", "d"],
        ["features", "--data", "d", "--out", "o", "--model", "m"],
        ["synth"],
        ["synth", "--out", "s", "--seed", "abc"],
        ["synth", "--out", "s", "--seed", "-1"],
        ["synth", "--out", "s", "--only", "nope"],
    ] as [[String]])
    func usageErrors(arguments: [String]) {
        guard case .failure = CLI.parse(arguments) else {
            Issue.record("expected a usage error for \(arguments)")
            return
        }
    }

    @Test("exit codes: 0 success, 2 usage, 1 runtime")
    func exitCodes() throws {
        var errors: [String] = []
        #expect(CLI.main(arguments: ["bogus"], out: { _ in }, err: { errors.append($0) }) == 2)
        #expect(errors.first?.contains("usage:") == true)
        #expect(CLI.main(arguments: ["--help"], out: { _ in }, err: { _ in }) == 0)

        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("absent").path
        #expect(CLI.main(arguments: ["replay", "--data", missing, "--out", dir.appendingPathComponent("o.json").path],
                         out: { _ in }, err: { _ in }) == 1)
    }

    @Test("usage text has no em dashes")
    func usageText() {
        #expect(!CLI.usage.contains("\u{2014}"))
    }
}

// MARK: - Session mode

/// A synthetic set the engine can count: a body seen head-on from the floor.
private func planted(reps: Int, seed: UInt64 = 1) -> RecordedSession {
    SyntheticSessions.cleanSet(reps: reps, tempo: .normal, seed: seed, options: .foreshortened())
}

private func sessionReplay(_ session: RecordedSession, config: SessionConfig = .default) -> SessionResult {
    Replay.replay(session, file: "test.json", engine: WorkoutSessionEngine(config: config))
}

@Suite("Replay modes")
struct ReplayModeTests {
    @Test("raw mode output for the synthetic dataset is unchanged from before session mode existed")
    func rawUnchanged() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticDataset.write(to: dir.appendingPathComponent("data"))
        let out = dir.appendingPathComponent("predictions.json")
        #expect(CLI.main(arguments: ["replay", "--data", dir.appendingPathComponent("data").path, "--out", out.path], out: { _ in }, err: { _ in }) == 0)
        let url = try #require(Bundle.module.url(forResource: "raw_replay_synthetic_seed1", withExtension: "json", subdirectory: "Fixtures"))
        #expect(try Data(contentsOf: out) == Data(contentsOf: url))
        // Passing the default mode by name changes nothing either.
        let named = dir.appendingPathComponent("named.json")
        #expect(CLI.main(arguments: ["replay", "--data", dir.appendingPathComponent("data").path, "--out", named.path, "--mode", "raw"], out: { _ in }, err: { _ in }) == 0)
        #expect(try Data(contentsOf: named) == Data(contentsOf: url))
    }

    @Test("raw output carries none of the session-only fields")
    func rawHasNoSessionFields() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticDataset.write(to: dir)
        let output = try Replay.run(directory: dir, config: .default, source: .heuristic)
        #expect(output.pipeline.mode == nil && output.pipeline.sessionConfig == nil)
        #expect(output.sessions.allSatisfy { $0.started == nil && $0.startTime == nil && $0.endPhase == nil && $0.gateCounts == nil })
    }

    @Test("session mode counts a planted set exactly and describes the take")
    func sessionCounts() throws {
        let result = sessionReplay(planted(reps: 6))
        #expect(result.predictedReps == 6)
        #expect(result.started == true)
        let start = try #require(result.startTime)
        #expect(start >= 0.9 && start < 1.3)
        #expect(result.endPhase == "active")
        #expect(result.repTimes.count == 6 && result.repTimes.allSatisfy { $0 > start })
        let gates = try #require(result.gateCounts)
        #expect(gates.total == result.frames)
        #expect(gates.passed > 0)
        #expect(result.frameCounts.total == result.frames)
    }

    @Test("session mode on takes the engine should reject")
    func sessionRejects() throws {
        // The legacy-geometry synthetic sets are tall bodies: the horizontal-body gate rejects them.
        let tall = sessionReplay(SyntheticSessions.cleanSet(reps: 5))
        #expect(tall.predictedReps == 0 && tall.started == false && tall.startTime == nil && tall.endPhase == "positioning")
        let gates = try #require(tall.gateCounts)
        #expect(gates.notHorizontal > 0 && gates.passed == 0)
        // The same take under the legacy session config is counted.
        #expect(sessionReplay(SyntheticSessions.cleanSet(reps: 5), config: .legacy).predictedReps == 5)
    }

    @Test("session mode records the mode and the config, and isDefaultConfig follows the session config")
    func sessionPipelineBlock() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticDataset.write(to: dir)
        let normal = try Replay.run(directory: dir, config: .default, source: .heuristic, mode: .session, sessionConfig: nil)
        #expect(normal.pipeline.mode == "session")
        #expect(normal.pipeline.sessionConfig == .default)
        #expect(normal.pipeline.isDefaultConfig)
        #expect(normal.sessions.count == SyntheticDataset.sessionCount)
        #expect(normal.sessions.allSatisfy { $0.gateCounts?.total == $0.frames })

        let legacy = try Replay.run(directory: dir, config: .default, source: .heuristic, mode: .session, sessionConfig: .legacy)
        #expect(!legacy.pipeline.isDefaultConfig)
        #expect(legacy.pipeline.sessionConfig == .legacy)
        // Under the legacy session config the synthetic clean sets are counted again.
        let clean = legacy.sessions.filter { $0.tags.cheat == .none && $0.kind == "set" }
        #expect(clean.allSatisfy { $0.predictedReps == $0.trueReps })
    }

    @Test("a session config file reaches the replay command, and --config replaces its pipeline")
    func sessionConfigFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data")
        try SyntheticDataset.write(to: data)

        let sessionPath = dir.appendingPathComponent("session.json")
        try Data(#"{"horizontalBodyGate": false, "plantedHandsGate": false, "startRequiresStraightArms": false}"#.utf8).write(to: sessionPath)
        let out = dir.appendingPathComponent("out.json")
        #expect(CLI.main(arguments: ["replay", "--data", data.path, "--out", out.path, "--mode", "session", "--session-config", sessionPath.path], out: { _ in }, err: { _ in }) == 0)
        let decoded = try JSONDecoder().decode(ReplayOutput.self, from: Data(contentsOf: out))
        #expect(decoded.pipeline.mode == "session")
        #expect(decoded.pipeline.sessionConfig == .legacy)
        #expect(decoded.sessions.contains { $0.predictedReps > 0 })

        let pipelinePath = dir.appendingPathComponent("pipeline.json")
        try Data(#"{"repCounter": {"minPhaseDuration": 30}}"#.utf8).write(to: pipelinePath)
        let merged = try CLI.loadSessionConfig(sessionPath.path, pipeline: CLI.loadConfig(pipelinePath.path))
        #expect(merged.pipeline.repCounter.minPhaseDuration == 30)
        #expect(!merged.horizontalBodyGate)
        #expect(throws: EvalError.self) { try CLI.loadSessionConfig(dir.appendingPathComponent("missing.json").path) }
    }

    @Test("running session mode twice gives identical bytes")
    func sessionDeterministic() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data")
        try SyntheticDataset.write(to: data)
        try planted(reps: 4).write(to: data.appendingPathComponent(RecordedSession.fileName(kind: .set, createdAt: "2026-01-11T10:00:00Z", id: planted(reps: 4).id)))
        var outputs: [Data] = []
        for name in ["a.json", "b.json"] {
            let path = dir.appendingPathComponent(name)
            #expect(CLI.main(arguments: ["replay", "--data", data.path, "--out", path.path, "--mode", "session"], out: { _ in }, err: { _ in }) == 0)
            outputs.append(try Data(contentsOf: path))
        }
        #expect(outputs[0] == outputs[1])
    }
}

@Suite("Features CSV session columns")
struct FeaturesSessionColumnTests {
    private func loaded(_ sessions: [RecordedSession]) -> [LoadedSession] {
        sessions.enumerated().map { LoadedSession(file: "s\($0.offset).json", session: $0.element) }
    }

    @Test("the original columns are unchanged and the new ones follow")
    func originalColumnsUnchanged() throws {
        // The first 33 columns of the synthetic dataset, hashed, as produced before the session columns existed.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticDataset.write(to: dir)
        let text = FeaturesCSV.render(sessions: try SessionLoader.load(directory: dir).sessions, config: .default)
        var hasher = SHA256()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).prefix(33)
            hasher.update(data: Data((cells.joined(separator: ",") + "\n").utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == "c3d9056b2b74dd294c7745ead0fa6f378f04845ded5b47afcbabf2ee85234d87")
    }

    @Test("the session columns describe each frame")
    func columns() throws {
        let text = FeaturesCSV.render(sessions: loaded([planted(reps: 3)]), config: .default)
        let rows = text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows.allSatisfy { $0.count == 39 })
        let last = try #require(rows.last)
        #expect(abs((Float(last[33]) ?? 0) - 0.4) < 0.1)
        #expect(Float(last[34]) != nil && Float(last[35]) != nil)
        #expect(last[36].isEmpty)
        #expect(last[37] == "active")
        #expect(last[38] == "3")
        #expect(rows.first?[37] == "positioning")
        #expect(Set(rows.map { $0[37] }).isSuperset(of: ["positioning", "active"]))
    }

    @Test("a session config changes the session columns only")
    func sessionConfigChangesOnlyNewColumns() {
        let sessions = loaded([SyntheticSessions.cleanSet(reps: 2)])
        let normal = FeaturesCSV.render(sessions: sessions, config: .default)
        let legacy = FeaturesCSV.render(sessions: sessions, config: .default, sessionConfig: .legacy)
        func base(_ text: String) -> [String] {
            text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).prefix(33).joined(separator: ",") }
        }
        #expect(base(normal) == base(legacy))
        #expect(normal != legacy)
    }

    @Test("the features command accepts a session config")
    func command() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data")
        try SyntheticDataset.write(to: data)
        let configPath = dir.appendingPathComponent("s.json")
        try Data(#"{"horizontalBodyGate": false}"#.utf8).write(to: configPath)
        let out = dir.appendingPathComponent("f.csv")
        let code = CLI.main(arguments: ["features", "--data", data.path, "--out", out.path, "--session-config", configPath.path], out: { _ in }, err: { _ in })
        #expect(code == 0)
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(!text.contains(",notHorizontal,"))
    }
}
