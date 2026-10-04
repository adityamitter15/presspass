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
        #expect(lines.dropFirst().dropLast().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 33 })
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
        #expect(CLI.parse(["replay", "--data", "d", "--out", "o.json"]) == .success(.replay(data: "d", out: "o.json", config: nil, model: nil)))
        #expect(CLI.parse(["replay", "--out=o.json", "--data=d", "--config", "c.json", "--model", "m.mlmodelc"])
            == .success(.replay(data: "d", out: "o.json", config: "c.json", model: "m.mlmodelc")))
        #expect(CLI.parse(["features", "--data", "d", "--out", "f.csv"]) == .success(.features(data: "d", out: "f.csv", config: nil)))
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
