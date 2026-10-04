import Foundation

/// Turns the live elbow angle into a display-only "how low are you" signal
/// and spots shallow attempts: descents that start but never reach the depth
/// the classifier needs, so the rep counter (rightly) ignores them.
///
/// Purely presentational. It reads `PipelineOutput` and never feeds anything
/// back, so it cannot change what `RepCounter` counts.
public struct DepthTracker {
    public struct Config: Equatable {
        /// Mean elbow angle at or above which the arms count as straight
        /// (depth 0). Defaults to the heuristic classifier's "up" threshold.
        public var upElbowDegrees: Float
        /// Mean elbow angle at or below which the person has reached full
        /// depth (depth 1). Defaults to the heuristic classifier's "down"
        /// threshold.
        public var downElbowDegrees: Float
        /// EMA alpha for the displayed depth, in (0, 1]. 1 means no smoothing.
        public var smoothing: Float
        /// A descent must reach at least this smoothed depth to count as an
        /// attempt.
        public var shallowMinDepth: Float
        /// A descent starts when smoothed depth rises above this and is over
        /// once it falls back below it.
        public var returnDepth: Float

        public static let `default` = Config()

        public init(
            upElbowDegrees: Float = HeuristicPoseClassifier.Config.default.upElbowDegrees,
            downElbowDegrees: Float = HeuristicPoseClassifier.Config.default.downElbowDegrees,
            smoothing: Float = 0.5,
            shallowMinDepth: Float = 0.35,
            returnDepth: Float = 0.15
        ) {
            self.upElbowDegrees = upElbowDegrees
            self.downElbowDegrees = downElbowDegrees
            self.smoothing = smoothing
            self.shallowMinDepth = shallowMinDepth
            self.returnDepth = returnDepth
        }
    }

    public enum Event: Equatable {
        case none
        /// A descent ended without a counted rep after getting at least
        /// `shallowMinDepth` of the way down. `peakDepth` is the smoothed
        /// peak of that descent.
        case shallowAttempt(peakDepth: Float)
    }

    private let config: Config
    private var inDescent = false
    private var repCountedThisDescent = false
    /// Whether the unsmoothed depth hit 1 (the down threshold) during this
    /// descent. Such a descent is deep enough to count, so if it was not
    /// counted the counter had another reason (too fast, posture), and
    /// calling it shallow would be wrong. It also keeps a full rep that the
    /// counter credits a few frames after the descent ends from being
    /// reported as shallow.
    private var reachedFullDepth = false

    /// Smoothed depth: 0 with the arms straight, 1 at the down threshold or lower.
    public private(set) var depth: Float = 0
    /// Highest smoothed depth of the descent in progress, 0 between descents.
    public private(set) var peakDepthThisDescent: Float = 0

    public init(config: Config = .default) {
        self.config = config
    }

    public mutating func reset() {
        depth = 0
        peakDepthThisDescent = 0
        inDescent = false
        repCountedThisDescent = false
        reachedFullDepth = false
    }

    /// Feeds one pipeline output. `repsBefore` is the rep count before this
    /// frame; `output.reps` is the count after it.
    ///
    /// A frame with no features or failing a posture gate pulls depth towards
    /// 0 and never emits an event, and a descent that dies out that way is
    /// dropped rather than reported, since the person may simply have left.
    public mutating func update(with output: PipelineOutput, repsBefore: Int) -> Event {
        let usable = output.features != nil && output.postureValid && output.requiredJointsConfident
        let raw = usable ? rawDepth(output.features) : 0
        depth += config.smoothing * (raw - depth)

        if !inDescent, depth > config.returnDepth {
            inDescent = true
            repCountedThisDescent = false
            reachedFullDepth = false
            peakDepthThisDescent = 0
        }
        guard inDescent else { return .none }

        if output.reps > repsBefore { repCountedThisDescent = true }
        if usable, raw >= 1 { reachedFullDepth = true }
        peakDepthThisDescent = max(peakDepthThisDescent, depth)

        guard depth < config.returnDepth else { return .none }

        let peak = peakDepthThisDescent
        let shallow = usable && !repCountedThisDescent && !reachedFullDepth && peak >= config.shallowMinDepth
        inDescent = false
        peakDepthThisDescent = 0
        return shallow ? .shallowAttempt(peakDepth: peak) : .none
    }

    private func rawDepth(_ features: [Float]?) -> Float {
        guard let features, features.count == PushupFeatureExtractor.featureDim else { return 0 }
        let left = features[PushupFeatureExtractor.leftElbowAngleIndex] * 180 / .pi
        let right = features[PushupFeatureExtractor.rightElbowAngleIndex] * 180 / .pi
        let mean = (left + right) / 2
        let span = max(config.upElbowDegrees - config.downElbowDegrees, 1)
        return min(max((config.upElbowDegrees - mean) / span, 0), 1)
    }
}
