import Foundation

/// Rep-counting state machine phases. `idle` is the state before the very
/// first confident up/down observation of a session; it behaves like `up`
/// for the purposes of the state machine (a rep only counts on a
/// down -> up transition), so starting a set already in the down position
/// still requires coming back up before it's counted.
public enum RepPhase {
    case idle
    case up
    case down
}

/// Everything `RepCounter` needs about one frame to advance its state
/// machine. Built by `PushupPipeline` from a `PoseFrame` + the
/// extracted feature vector + the active `PoseClassifier`'s output.
/// `RepCounter` itself never touches pose-detection/CoreML types, which
/// keeps it trivially testable.
public struct RepCounterFrameInput {
    public let timestamp: TimeInterval
    public let label: PoseLabel
    public let labelConfidence: Float
    /// Anti-cheat posture gate (`PostureGate`), computed for the current
    /// camera setup (front view: wrists must be below the shoulders in the
    /// image, i.e. hands planted on the floor). False = frame is ignored.
    public let postureValid: Bool
    /// False if any of the anti-cheat "required" joints (wrists,
    /// shoulders, hips) are below the confidence floor this frame.
    public let requiredJointsConfident: Bool

    public init(
        timestamp: TimeInterval,
        label: PoseLabel,
        labelConfidence: Float,
        postureValid: Bool,
        requiredJointsConfident: Bool
    ) {
        self.timestamp = timestamp
        self.label = label
        self.labelConfidence = labelConfidence
        self.postureValid = postureValid
        self.requiredJointsConfident = requiredJointsConfident
    }
}

/// Why the most recent frame didn't advance the rep count, surfaced to the
/// UI so the user gets feedback instead of a counter that silently stalls.
public enum RepCounterIgnoreReason: Equatable {
    case none
    case lowConfidence
    case notInPushupPosture
}

/// Counts pushup reps from a stream of per-frame pose classifications.
///
/// - EMA-smooths the confidence of the `up` and `down` labels (alpha 0.3)
///   so single noisy frames can't flip the phase.
/// - Hysteresis: a phase is entered once its smoothed confidence reaches
///   0.6, and only exited once it drops to 0.4. This is what keeps a
///   classifier hovering near a boundary from chattering back and forth.
/// - Minimum 0.5s dwell time in each phase before a further transition is
///   accepted, so a fast partial movement can't register as a phase
///   change.
/// - A rep counts on every down -> up transition. Reps started less than
///   one second after the previous counted rep are rejected (tracked
///   separately) rather than silently dropped, so rapid-fire cheating
///   shows up in the UI instead of just not incrementing.
public final class RepCounter {
    /// Tunable thresholds. The defaults are the shipped behaviour.
    public struct Config: Equatable {
        public var emaAlpha: Float
        public var enterThreshold: Float
        public var exitThreshold: Float
        public var minPhaseDuration: TimeInterval
        public var minSecondsBetweenReps: TimeInterval

        public static let `default` = Config()

        public init(
            emaAlpha: Float = 0.3,
            enterThreshold: Float = 0.6,
            exitThreshold: Float = 0.4,
            minPhaseDuration: TimeInterval = 0.5,
            minSecondsBetweenReps: TimeInterval = 1.0
        ) {
            self.emaAlpha = emaAlpha
            self.enterThreshold = enterThreshold
            self.exitThreshold = exitThreshold
            self.minPhaseDuration = minPhaseDuration
            self.minSecondsBetweenReps = minSecondsBetweenReps
        }
    }

    public private(set) var reps: Int = 0
    public private(set) var rejectedReps: Int = 0
    public private(set) var phase: RepPhase = .idle
    public private(set) var currentLabel: PoseLabel = .notPushup
    public private(set) var lastIgnoreReason: RepCounterIgnoreReason = .none

    private let config: Config

    /// Confidence floor for the anti-cheat "required joints" check.
    public static let requiredJointConfidenceFloor: Float = 0.3

    private var emaUp: Float = 0
    private var emaDown: Float = 0
    private var phaseEnteredAt: TimeInterval?
    private var lastCountedRepAt: TimeInterval?

    public init(config: Config = .default) {
        self.config = config
    }

    public func reset() {
        reps = 0
        rejectedReps = 0
        phase = .idle
        currentLabel = .notPushup
        lastIgnoreReason = .none
        emaUp = 0
        emaDown = 0
        phaseEnteredAt = nil
        lastCountedRepAt = nil
    }

    /// Feeds one frame's classification into the state machine. Frames
    /// that fail an anti-cheat check are ignored entirely (they don't
    /// smooth into the EMA and can't advance the phase), but
    /// `lastIgnoreReason` is updated so the UI can explain why the
    /// counter didn't move.
    @discardableResult
    public func process(_ input: RepCounterFrameInput) -> RepPhase {
        guard input.requiredJointsConfident else {
            lastIgnoreReason = .lowConfidence
            return phase
        }

        guard input.postureValid else {
            lastIgnoreReason = .notInPushupPosture
            return phase
        }

        lastIgnoreReason = .none
        currentLabel = input.label

        let upSignal: Float = input.label == .up ? input.labelConfidence : 0
        let downSignal: Float = input.label == .down ? input.labelConfidence : 0
        emaUp = config.emaAlpha * upSignal + (1 - config.emaAlpha) * emaUp
        emaDown = config.emaAlpha * downSignal + (1 - config.emaAlpha) * emaDown

        let proposedPhase = nextPhase(at: input.timestamp)
        if proposedPhase != phase {
            if phase == .down && proposedPhase == .up {
                countRep(at: input.timestamp)
            }
            phase = proposedPhase
            phaseEnteredAt = input.timestamp
        } else if phaseEnteredAt == nil {
            phaseEnteredAt = input.timestamp
        }

        return phase
    }

    private func nextPhase(at timestamp: TimeInterval) -> RepPhase {
        let timeInPhase = phaseEnteredAt.map { timestamp - $0 } ?? .infinity
        if timeInPhase < config.minPhaseDuration {
            return phase
        }

        switch phase {
        case .idle:
            if emaUp >= config.enterThreshold { return .up }
            if emaDown >= config.enterThreshold { return .down }
            return .idle
        case .up:
            // True hysteresis: only leave `up` once its own confidence has
            // decayed past the exit threshold *and* `down` has risen past
            // the (higher) enter threshold.
            if emaUp <= config.exitThreshold && emaDown >= config.enterThreshold { return .down }
            return .up
        case .down:
            if emaDown <= config.exitThreshold && emaUp >= config.enterThreshold { return .up }
            return .down
        }
    }

    private func countRep(at timestamp: TimeInterval) {
        if let last = lastCountedRepAt, timestamp - last < config.minSecondsBetweenReps {
            rejectedReps += 1
            return
        }
        reps += 1
        lastCountedRepAt = timestamp
    }
}
