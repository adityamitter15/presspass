import Foundation

/// The hands-free flow of one workout session, as a small deterministic
/// state machine driven by frames and time: wait for a pushup posture, count
/// while the person stays in it, then count down to an automatic finish once
/// they leave. It never looks at the pose itself, only at whether the frame
/// passed both posture gates, and it does not touch rep counting.
public struct WorkoutFlow {
    public enum Phase: Equatable {
        /// Waiting for a valid pushup posture.
        case positioning
        /// Counting.
        case active
        /// The person has left the posture; counts down to an automatic finish.
        case finishing(secondsRemaining: Double)
        case finished
    }

    public struct Config: Equatable {
        /// The posture must stay valid this long to start.
        public var startHold: Double
        /// Seconds without a valid posture, while active, before the finishing countdown begins.
        public var idleBeforeFinishing: Double
        /// Length of the finishing countdown.
        public var finishingCountdown: Double
        /// Do not auto-finish a session with zero reps.
        public var requiresRepToAutoFinish: Bool

        public static let `default` = Config()

        public init(
            startHold: Double = 1.0,
            idleBeforeFinishing: Double = 3.0,
            finishingCountdown: Double = 3.0,
            requiresRepToAutoFinish: Bool = true
        ) {
            self.startHold = startHold
            self.idleBeforeFinishing = idleBeforeFinishing
            self.finishingCountdown = finishingCountdown
            self.requiresRepToAutoFinish = requiresRepToAutoFinish
        }
    }

    private let config: Config
    /// When the current unbroken run of valid frames began (positioning).
    private var validSince: TimeInterval?
    /// When the current unbroken run of invalid frames began (active).
    private var invalidSince: TimeInterval?
    /// When the finishing countdown began.
    private var countdownStart: TimeInterval = 0

    public private(set) var phase: Phase = .positioning

    public init(config: Config = .default) {
        self.config = config
    }

    public mutating func reset() {
        phase = .positioning
        validSince = nil
        invalidSince = nil
        countdownStart = 0
    }

    /// `postureValid` means the frame passed both posture gates. `timestamp`
    /// is the frame timestamp in seconds. `reps` is the current count.
    public mutating func update(postureValid: Bool, reps: Int, timestamp: TimeInterval) {
        switch phase {
        case .positioning:
            guard postureValid else {
                validSince = nil
                return
            }
            let since = validSince ?? timestamp
            validSince = since
            if timestamp - since >= config.startHold {
                phase = .active
                validSince = nil
                invalidSince = nil
            }

        case .active:
            guard !postureValid else {
                invalidSince = nil
                return
            }
            let since = invalidSince ?? timestamp
            invalidSince = since
            guard timestamp - since >= config.idleBeforeFinishing else { return }
            invalidSince = nil
            if reps > 0 || !config.requiresRepToAutoFinish {
                phase = .finishing(secondsRemaining: config.finishingCountdown)
                countdownStart = timestamp
            } else {
                phase = .positioning
                validSince = nil
            }

        case .finishing:
            if postureValid {
                phase = .active
                invalidSince = nil
                return
            }
            let remaining = config.finishingCountdown - (timestamp - countdownStart)
            phase = remaining > 0 ? .finishing(secondsRemaining: remaining) : .finished

        case .finished:
            break
        }
    }

    /// Manual finish from the UI, valid in any phase except `finished`.
    public mutating func finishNow() {
        phase = .finished
    }
}
