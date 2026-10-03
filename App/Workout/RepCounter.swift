import Foundation

/// Rep-counting state machine phases. `idle` is the state before the very
/// first confident up/down observation of a session; it behaves like `up`
/// for the purposes of the state machine (a rep only counts on a
/// down -> up transition), so starting a set already in the down position
/// still requires coming back up before it's counted.
enum RepPhase {
    case idle
    case up
    case down
}

/// Everything `RepCounter` needs about one frame to advance its state
/// machine. Built by the workout view model from a `PoseFrame` + the
/// extracted feature vector + the active `PoseClassifier`'s output —
/// `RepCounter` itself never touches pose-detection/CoreML types, which
/// keeps it trivially testable.
struct RepCounterFrameInput {
    let timestamp: TimeInterval
    let label: PoseLabel
    let labelConfidence: Float
    /// Anti-cheat posture gate, computed by the view model for the current
    /// camera setup (front view: wrists must be below the shoulders in the
    /// image, i.e. hands planted on the floor). False = frame is ignored.
    let postureValid: Bool
    /// False if any of the anti-cheat "required" joints (wrists,
    /// shoulders, hips) are below the confidence floor this frame.
    let requiredJointsConfident: Bool
}

/// Why the most recent frame didn't advance the rep count, surfaced to the
/// UI so the user gets feedback instead of a counter that silently stalls.
enum RepCounterIgnoreReason: Equatable {
    case none
    case lowConfidence
    case notInPushupPosture
}

/// Counts pushup reps from a stream of per-frame pose classifications.
///
/// - EMA-smooths the confidence of the `up` and `down` labels (alpha 0.3)
///   so single noisy frames can't flip the phase.
/// - Hysteresis: a phase is entered once its smoothed confidence reaches
///   0.6, and only exited once it drops to 0.4 — this is what keeps a
///   classifier hovering near a boundary from chattering back and forth.
/// - Minimum 0.5s dwell time in each phase before a further transition is
///   accepted, so a fast partial movement can't register as a phase
///   change.
/// - A rep counts on every down -> up transition. Reps started less than
///   one second after the previous counted rep are rejected (tracked
///   separately) rather than silently dropped, so rapid-fire cheating
///   shows up in the UI instead of just not incrementing.
final class RepCounter {
    private(set) var reps: Int = 0
    private(set) var rejectedReps: Int = 0
    private(set) var phase: RepPhase = .idle
    private(set) var currentLabel: PoseLabel = .notPushup
    private(set) var lastIgnoreReason: RepCounterIgnoreReason = .none

    private let emaAlpha: Float = 0.3
    private let enterThreshold: Float = 0.6
    private let exitThreshold: Float = 0.4
    private let minPhaseDuration: TimeInterval = 0.5
    private let minSecondsBetweenReps: TimeInterval = 1.0

    /// Confidence floor for the anti-cheat "required joints" check.
    static let requiredJointConfidenceFloor: Float = 0.3

    private var emaUp: Float = 0
    private var emaDown: Float = 0
    private var phaseEnteredAt: TimeInterval?
    private var lastCountedRepAt: TimeInterval?

    func reset() {
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
    func process(_ input: RepCounterFrameInput) -> RepPhase {
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
        emaUp = emaAlpha * upSignal + (1 - emaAlpha) * emaUp
        emaDown = emaAlpha * downSignal + (1 - emaAlpha) * emaDown

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
        if timeInPhase < minPhaseDuration {
            return phase
        }

        switch phase {
        case .idle:
            if emaUp >= enterThreshold { return .up }
            if emaDown >= enterThreshold { return .down }
            return .idle
        case .up:
            // True hysteresis: only leave `up` once its own confidence has
            // decayed past the exit threshold *and* `down` has risen past
            // the (higher) enter threshold.
            if emaUp <= exitThreshold && emaDown >= enterThreshold { return .down }
            return .up
        case .down:
            if emaDown <= exitThreshold && emaUp >= enterThreshold { return .up }
            return .down
        }
    }

    private func countRep(at timestamp: TimeInterval) {
        if let last = lastCountedRepAt, timestamp - last < minSecondsBetweenReps {
            rejectedReps += 1
            return
        }
        reps += 1
        lastCountedRepAt = timestamp
    }
}
