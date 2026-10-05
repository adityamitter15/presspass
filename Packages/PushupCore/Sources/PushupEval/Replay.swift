import Foundation
import PushupCore

/// Which pose classifier a replay uses.
public enum ClassifierSource: Equatable {
    /// `HeuristicPoseClassifier` built from the config, a fresh one per session.
    case heuristic
    /// A compiled `.mlmodelc`.
    case coreML(modelURL: URL)

    public var name: String {
        switch self {
        case .heuristic: return "heuristic"
        case .coreML: return "coreml"
        }
    }
}

/// What a replay runs each take through.
public enum ReplayMode: String, Equatable {
    /// A bare `PushupPipeline`: the counting path alone, no start, end or gate logic.
    case raw
    /// A fresh `WorkoutSessionEngine`: the behaviour the app ships.
    case session
}

/// Frames of one take by the session engine's first failing check, plus the
/// frames that passed every check. The six counts add up to the number of frames.
public struct GateCounts: Codable, Equatable {
    public var noBody = 0
    public var lowConfidence = 0
    public var notInPosture = 0
    public var notHorizontal = 0
    public var handsMoving = 0
    /// No check failed: a valid planted posture.
    public var passed = 0

    public var total: Int { noBody + lowConfidence + notInPosture + notHorizontal + handsMoving + passed }

    mutating func tally(_ failure: WorkoutSessionEngine.GateFailure?) {
        switch failure {
        case .noBody: noBody += 1
        case .lowConfidence: lowConfidence += 1
        case .notInPosture: notInPosture += 1
        case .notHorizontal: notHorizontal += 1
        case .handsMoving: handsMoving += 1
        case nil: passed += 1
        }
    }
}

/// How each frame of a session was handled. The five counts add up to the
/// number of frames.
public struct FrameCounts: Codable, Equatable {
    /// No joints at all (nothing detected).
    public var noBody = 0
    /// Joints present, but the feature extractor's confidence gate failed.
    public var featuresNil = 0
    /// Features extracted, a required joint below the confidence floor.
    public var lowConfidence = 0
    /// Features extracted, posture gate failed (wrists not below shoulders).
    public var notInPosture = 0
    /// Reached the rep counter's state machine.
    public var processed = 0

    public var total: Int { noBody + featuresNil + lowConfidence + notInPosture + processed }
}

/// The replay result for one session.
public struct SessionResult: Codable, Equatable {
    public var id: String
    public var file: String
    public var kind: String
    public var subject: String
    public var createdAt: String
    public var tags: RecordedSession.Tags
    public var notes: String
    public var trueReps: Int?
    public var live: LiveResult?
    public var predictedReps: Int
    public var rejectedReps: Int
    /// The frame `t` at which each counted rep was registered.
    public var repTimes: [Double]
    public var frames: Int
    public var durationSeconds: Double
    public var meanFps: Double
    /// In session mode these describe how the take looked to the frame alone
    /// (the same buckets as in raw mode); `gateCounts` has the engine's view.
    public var frameCounts: FrameCounts
    // Session mode only. Absent in raw mode, so raw output does not change.
    /// Whether the engine ever left positioning.
    public var started: Bool?
    /// Frame time of the start of the last session the engine began, nil if it never started.
    public var startTime: Double?
    /// The engine's phase after the last frame: positioning, active, finishing or finished.
    public var endPhase: String?
    public var gateCounts: GateCounts?
}

public struct PipelineDescription: Codable, Equatable {
    public var classifier: String
    public var featureVersion: String
    /// True when `config` equals `PipelineConfig.default`. Written so the
    /// report does not need its own copy of the default thresholds.
    public var isDefaultConfig: Bool
    /// File name of the Core ML model, when one was used.
    public var model: String?
    public var config: PipelineConfig
    // Session mode only. Absent in raw mode, so raw output does not change.
    /// "session" when the takes were run through `WorkoutSessionEngine`.
    public var mode: String?
    /// The full session config used, `config` is its `pipeline`.
    public var sessionConfig: SessionConfig?
}

public struct ReplayOutput: Codable, Equatable {
    public var schema: Int
    public var tool: String
    public var pipeline: PipelineDescription
    public var sessions: [SessionResult]
    public var skipped: [SkippedFile]
}

public enum Replay {
    public static let outputSchema = 1
    public static let toolName = "pushup-eval"

    /// Replays every session in `directory` and returns the full result. The
    /// output holds no wall-clock data, so the same inputs encode to the same
    /// bytes. In `.session` mode `sessionConfig` is used and `config` is ignored.
    public static func run(
        directory: URL,
        config: PipelineConfig,
        source: ClassifierSource,
        mode: ReplayMode = .raw,
        sessionConfig: SessionConfig? = nil
    ) throws -> ReplayOutput {
        let loaded = try SessionLoader.load(directory: directory)
        let shared = try sharedClassifier(for: source)

        switch mode {
        case .raw:
            let results = loaded.sessions.map { entry in
                replay(entry.session, file: entry.file, pipeline: config.makePipeline(classifier: shared))
            }
            return ReplayOutput(
                schema: outputSchema,
                tool: toolName,
                pipeline: PipelineDescription(
                    classifier: source.name,
                    featureVersion: PushupFeatureExtractor.featureVersion,
                    isDefaultConfig: config == .default,
                    model: modelName(source),
                    config: config
                ),
                sessions: results,
                skipped: loaded.skipped
            )
        case .session:
            let session = sessionConfig ?? SessionConfig(pipeline: config)
            let results = loaded.sessions.map { entry in
                replay(entry.session, file: entry.file, engine: WorkoutSessionEngine(config: session, classifier: shared))
            }
            return ReplayOutput(
                schema: outputSchema,
                tool: toolName,
                pipeline: PipelineDescription(
                    classifier: source.name,
                    featureVersion: PushupFeatureExtractor.featureVersion,
                    isDefaultConfig: session == .default,
                    model: modelName(source),
                    config: session.pipeline,
                    mode: mode.rawValue,
                    sessionConfig: session
                ),
                sessions: results,
                skipped: loaded.skipped
            )
        }
    }

    /// Feeds one session through `pipeline` (which must be fresh) in frame
    /// order and tallies the result.
    public static func replay(_ session: RecordedSession, file: String, pipeline: PushupPipeline) -> SessionResult {
        var counts = FrameCounts()
        var repTimes: [Double] = []
        var reps = 0
        var rejected = 0

        for frame in session.poseFrames() {
            let output = pipeline.process(frame)
            counts.tally(frame: frame, output: output)
            if output.reps > reps {
                repTimes.append(contentsOf: Array(repeating: frame.timestamp, count: output.reps - reps))
            }
            reps = output.reps
            rejected = output.rejectedReps
        }

        let duration = (session.frames.last?.t ?? 0) - (session.frames.first?.t ?? 0)
        let meanFps = duration > 0 ? Double(session.frames.count - 1) / duration : 0
        return SessionResult(
            id: session.id,
            file: file,
            kind: session.kind.rawValue,
            subject: session.subject,
            createdAt: session.createdAt,
            tags: session.tags,
            notes: session.notes,
            trueReps: session.trueReps,
            live: session.live,
            predictedReps: reps,
            rejectedReps: rejected,
            repTimes: repTimes,
            frames: session.frames.count,
            durationSeconds: round(duration, places: 6),
            meanFps: round(meanFps, places: 3),
            frameCounts: counts
        )
    }

    /// Feeds one session through `engine` (which must be fresh) in frame order.
    /// `predictedReps` and `repTimes` are the engine's, so a set that was never
    /// started, or that stopped being counted, shows exactly that.
    public static func replay(_ session: RecordedSession, file: String, engine: WorkoutSessionEngine) -> SessionResult {
        var counts = FrameCounts()
        var gates = GateCounts()
        var startTime: Double?

        for frame in session.poseFrames() {
            counts.tally(frame: frame)
            let output = engine.process(frame)
            gates.tally(output.gateFailure)
            if output.events.contains(.started) { startTime = frame.timestamp }
        }

        let duration = (session.frames.last?.t ?? 0) - (session.frames.first?.t ?? 0)
        let meanFps = duration > 0 ? Double(session.frames.count - 1) / duration : 0
        return SessionResult(
            id: session.id,
            file: file,
            kind: session.kind.rawValue,
            subject: session.subject,
            createdAt: session.createdAt,
            tags: session.tags,
            notes: session.notes,
            trueReps: session.trueReps,
            live: session.live,
            predictedReps: engine.reps,
            rejectedReps: engine.rejectedReps,
            repTimes: engine.repTimes,
            frames: session.frames.count,
            durationSeconds: round(duration, places: 6),
            meanFps: round(meanFps, places: 3),
            frameCounts: counts,
            started: startTime != nil,
            startTime: startTime.map { round($0, places: 6) },
            endPhase: engine.phase.name,
            gateCounts: gates
        )
    }

    /// The Core ML classifier is stateless, so one instance is loaded up front
    /// (failing early) and shared. The heuristic keeps state between frames,
    /// so `nil` here makes every session build its own.
    static func sharedClassifier(for source: ClassifierSource) throws -> PoseClassifier? {
        switch source {
        case .heuristic:
            return nil
        case .coreML(let url):
            guard let classifier = CoreMLPoseClassifier.load(compiledModelURL: url) else {
                throw EvalError.modelLoadFailed(url.path)
            }
            return classifier
        }
    }

    private static func modelName(_ source: ClassifierSource) -> String? {
        if case .coreML(let url) = source { return url.lastPathComponent }
        return nil
    }

    static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        let result = (value * scale).rounded() / scale
        return result == 0 ? 0 : result
    }

    /// Pretty-printed JSON with sorted keys, so output is byte-stable.
    public static func encode(_ output: ReplayOutput) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(output)
    }
}

extension FrameCounts {
    /// Puts one frame in exactly one bucket. The order matters: a frame that
    /// never reached the classifier carries the counter's stale ignore
    /// reason, which must not be read.
    mutating func tally(frame: PoseFrame, output: PipelineOutput) {
        if frame.joints.isEmpty {
            noBody += 1
        } else if output.features == nil {
            featuresNil += 1
        } else {
            switch output.ignoreReason {
            case .lowConfidence: lowConfidence += 1
            case .notInPushupPosture: notInPosture += 1
            case .none: processed += 1
            }
        }
    }
}

extension FrameCounts {
    /// The same buckets as `tally(frame:output:)`, from the frame alone. The
    /// buckets only depend on the frame (the feature gate, the confidence
    /// floor, the posture gate), never on counter state, so this agrees with
    /// the pipeline-based tally frame by frame.
    mutating func tally(frame: PoseFrame) {
        if frame.joints.isEmpty {
            noBody += 1
        } else if PushupFeatureExtractor.extract(frame.joints) == nil {
            featuresNil += 1
        } else if !PostureGate.requiredJointsConfident(frame.joints) {
            lowConfidence += 1
        } else if !PostureGate.isPushupPosture(frame.joints) {
            notInPosture += 1
        } else {
            processed += 1
        }
    }
}

extension WorkoutSessionEngine.Phase {
    /// The phase as a plain word, for output files.
    public var name: String {
        switch self {
        case .positioning: "positioning"
        case .active: "active"
        case .finishing: "finishing"
        case .finished: "finished"
        }
    }
}
