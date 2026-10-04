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
    public var frameCounts: FrameCounts
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
    /// bytes.
    public static func run(
        directory: URL,
        config: PipelineConfig,
        source: ClassifierSource
    ) throws -> ReplayOutput {
        let loaded = try SessionLoader.load(directory: directory)
        let shared = try sharedClassifier(for: source)
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
