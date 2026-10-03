import Foundation
import Testing
import PushupCore

/// Feeds label streams into a `RepCounter` at 30 fps with synthetic time.
private final class Driver {
    let counter: RepCounter
    private(set) var time: TimeInterval = 0
    static let frameInterval: TimeInterval = 1.0 / 30.0

    init(config: RepCounter.Config = .default) {
        counter = RepCounter(config: config)
    }

    /// Holds `label` for `seconds` of synthetic time.
    func hold(
        _ label: PoseLabel,
        seconds: TimeInterval,
        confidence: Float = 0.9,
        postureValid: Bool = true,
        requiredJointsConfident: Bool = true
    ) {
        let frames = Int((seconds / Self.frameInterval).rounded())
        for _ in 0..<frames {
            feed(label, confidence: confidence, postureValid: postureValid, requiredJointsConfident: requiredJointsConfident)
        }
    }

    func feed(
        _ label: PoseLabel,
        confidence: Float = 0.9,
        postureValid: Bool = true,
        requiredJointsConfident: Bool = true
    ) {
        counter.process(RepCounterFrameInput(
            timestamp: time,
            label: label,
            labelConfidence: confidence,
            postureValid: postureValid,
            requiredJointsConfident: requiredJointsConfident
        ))
        time += Self.frameInterval
    }

    /// Settles into `up`: feeds up frames until the phase becomes `up`.
    func settleIntoUp() {
        var guardFrames = 0
        while counter.phase != .up && guardFrames < 300 {
            feed(.up)
            guardFrames += 1
        }
    }

    /// One clean rep: down for `downSeconds`, then up for `upSeconds`.
    func cleanRep(downSeconds: TimeInterval = 1.0, upSeconds: TimeInterval = 1.0) {
        hold(.down, seconds: downSeconds)
        hold(.up, seconds: upSeconds)
    }
}

@Suite("RepCounter")
struct RepCounterTests {
    @Test("N clean reps count exactly N", arguments: [1, 2, 3, 5, 10, 25])
    func cleanRepsCountExactly(_ n: Int) {
        let driver = Driver()
        driver.hold(.up, seconds: 1.0)
        for _ in 0..<n { driver.cleanRep() }
        #expect(driver.counter.reps == n)
        #expect(driver.counter.rejectedReps == 0)
        #expect(driver.counter.phase == .up)
    }

    @Test("starting in down needs a return to up before the first count")
    func startingInDownNeedsReturnToUp() {
        let driver = Driver()
        driver.hold(.down, seconds: 1.5)
        #expect(driver.counter.phase == .down)
        #expect(driver.counter.reps == 0)

        driver.hold(.up, seconds: 1.0)
        #expect(driver.counter.phase == .up)
        #expect(driver.counter.reps == 1)
    }

    @Test("a stream that never reaches a confident down counts nothing")
    func neverConfidentDownCountsZero() {
        // Down at the heuristic's ambiguous-band confidence (0.35) smooths to
        // at most 0.35, below the 0.6 enter threshold.
        let driver = Driver()
        driver.hold(.up, seconds: 1.0)
        driver.hold(.down, seconds: 3.0, confidence: 0.35)
        driver.hold(.up, seconds: 1.0)
        driver.hold(.down, seconds: 3.0, confidence: 0.35)
        driver.hold(.up, seconds: 1.0)
        #expect(driver.counter.reps == 0)
        #expect(driver.counter.rejectedReps == 0)
        #expect(driver.counter.phase == .up)
    }

    @Test("a stream of not_pushup labels never leaves idle")
    func notPushupStaysIdle() {
        let driver = Driver()
        driver.hold(.notPushup, seconds: 5.0)
        #expect(driver.counter.phase == .idle)
        #expect(driver.counter.reps == 0)
    }

    @Test("single-frame label flips inside the up phase create no reps")
    func chatterInsideUpCreatesNothing() {
        let driver = Driver()
        driver.hold(.up, seconds: 1.0)
        for _ in 0..<60 {
            driver.hold(.up, seconds: 4.0 / 30.0)
            driver.feed(.down)
        }
        #expect(driver.counter.reps == 0)
        #expect(driver.counter.phase == .up)
    }

    @Test("alternating up/down chatter between a down and an up adds no extra reps")
    func chatterAtBoundaryAddsNothing() {
        let driver = Driver()
        driver.hold(.up, seconds: 1.0)
        driver.hold(.down, seconds: 1.0)
        // Alternating every frame keeps both smoothed values near 0.4 to 0.55,
        // never past the 0.6 enter threshold, so the phase holds.
        for i in 0..<90 {
            driver.feed(i.isMultiple(of: 2) ? .up : .down)
        }
        #expect(driver.counter.phase == .down)
        #expect(driver.counter.reps == 0)

        driver.hold(.up, seconds: 1.0)
        #expect(driver.counter.reps == 1)
        #expect(driver.counter.rejectedReps == 0)
    }

    @Test("a down burst shorter than the dwell time right after entering up is not accepted")
    func shortPhaseNotAccepted() {
        let driver = Driver()
        driver.settleIntoUp()
        #expect(driver.counter.phase == .up)

        // 0.4 s of confident down straight after entering up: below the 0.5 s
        // minimum dwell, so the phase must not change.
        driver.hold(.down, seconds: 0.4)
        #expect(driver.counter.phase == .up)

        driver.hold(.up, seconds: 2.0)
        #expect(driver.counter.phase == .up)
        #expect(driver.counter.reps == 0)
    }

    @Test("the same down burst held past the dwell time is accepted and counts")
    func longPhaseAccepted() {
        let driver = Driver()
        driver.settleIntoUp()
        driver.hold(.down, seconds: 1.0)
        #expect(driver.counter.phase == .down)
        driver.hold(.up, seconds: 1.0)
        #expect(driver.counter.reps == 1)
    }

    @Test("reps completed too soon after the previous counted rep are rejected, not counted")
    func tooFastRepsAreRejected() {
        // With the shipped dwell (0.5 s per phase) a rep cycle can never be
        // shorter than 1.0 s, so the spacing rule only bites once the dwell is
        // relaxed. Relax it to 0.2 s and run 0.8 s cycles.
        let driver = Driver(config: RepCounter.Config(minPhaseDuration: 0.2))
        driver.hold(.up, seconds: 1.0)
        driver.cleanRep(downSeconds: 0.4, upSeconds: 0.4)
        driver.cleanRep(downSeconds: 0.4, upSeconds: 0.4)
        driver.cleanRep(downSeconds: 0.4, upSeconds: 0.4)
        driver.cleanRep(downSeconds: 0.4, upSeconds: 0.4)
        driver.hold(.up, seconds: 1.0)

        #expect(driver.counter.reps >= 1)
        #expect(driver.counter.rejectedReps >= 1)
        // 0.8 s cycles against a 1.0 s minimum: every counted rep is followed by a rejection or a gap.
        #expect(driver.counter.reps + driver.counter.rejectedReps == 4)
        #expect(driver.counter.reps < 4)
    }

    // NOTE(review): with the default Config the spacing rule (minSecondsBetweenReps = 1.0)
    // is redundant. Counting needs a down -> up transition, and each phase must
    // last at least minPhaseDuration (0.5 s) before it can be left, so two
    // counted reps are always at least 1.0 s apart and `rejectedReps` stays 0
    // however fast the user moves. The rule can only fire with a shorter dwell
    // or a longer minSecondsBetweenReps. This test pins the current behaviour.
    @Test("with the default config the fastest possible cadence is never rejected")
    func defaultConfigNeverRejects() {
        let driver = Driver()
        driver.hold(.up, seconds: 1.0)
        for _ in 0..<10 { driver.cleanRep(downSeconds: 0.6, upSeconds: 0.6) }
        driver.hold(.up, seconds: 1.0)
        #expect(driver.counter.rejectedReps == 0)
        #expect(driver.counter.reps > 0)
    }

    @Test("low required-joint confidence sets lowConfidence and freezes the state machine")
    func lowConfidenceIgnored() {
        let driver = Driver()
        driver.hold(.up, seconds: 2.0, requiredJointsConfident: false)
        #expect(driver.counter.lastIgnoreReason == .lowConfidence)
        #expect(driver.counter.phase == .idle)
        #expect(driver.counter.currentLabel == .notPushup)

        // The ignored frames must not have fed the smoothed confidence: a
        // single valid up frame cannot reach the 0.6 enter threshold.
        driver.feed(.up)
        #expect(driver.counter.lastIgnoreReason == .none)
        #expect(driver.counter.phase == .idle)
    }

    @Test("a posture failure sets notInPushupPosture and freezes the state machine")
    func postureIgnored() {
        let driver = Driver()
        driver.hold(.up, seconds: 2.0, postureValid: false)
        #expect(driver.counter.lastIgnoreReason == .notInPushupPosture)
        #expect(driver.counter.phase == .idle)
        #expect(driver.counter.currentLabel == .notPushup)

        driver.feed(.up)
        #expect(driver.counter.lastIgnoreReason == .none)
        #expect(driver.counter.phase == .idle)
    }

    @Test("when both gates fail, low confidence is reported first")
    func lowConfidenceTakesPrecedence() {
        let driver = Driver()
        driver.feed(.up, postureValid: false, requiredJointsConfident: false)
        #expect(driver.counter.lastIgnoreReason == .lowConfidence)
    }

    @Test("ignored frames in the middle of a rep neither advance nor reset it")
    func ignoredFramesDoNotDisturbARep() {
        let driver = Driver()
        driver.hold(.up, seconds: 1.0)
        driver.hold(.down, seconds: 1.0)
        #expect(driver.counter.phase == .down)
        driver.hold(.up, seconds: 3.0, postureValid: false)
        #expect(driver.counter.phase == .down)
        #expect(driver.counter.reps == 0)
        driver.hold(.up, seconds: 1.0)
        #expect(driver.counter.reps == 1)
    }

    @Test("reset returns everything to the initial state")
    func resetRestoresInitialState() {
        let driver = Driver()
        driver.hold(.up, seconds: 1.0)
        driver.cleanRep()
        driver.cleanRep()
        driver.hold(.up, seconds: 1.0, postureValid: false)
        #expect(driver.counter.reps == 2)
        #expect(driver.counter.lastIgnoreReason == .notInPushupPosture)

        driver.counter.reset()
        #expect(driver.counter.reps == 0)
        #expect(driver.counter.rejectedReps == 0)
        #expect(driver.counter.phase == .idle)
        #expect(driver.counter.currentLabel == .notPushup)
        #expect(driver.counter.lastIgnoreReason == .none)
    }

    @Test("after reset the counter behaves like a fresh one, even with timestamps restarting at zero")
    func resetThenReplayMatchesFresh() {
        let used = Driver()
        used.hold(.up, seconds: 1.0)
        for _ in 0..<3 { used.cleanRep() }
        used.counter.reset()

        // Drive the reset counter with timestamps restarting at 0, and a
        // fresh counter with the same stream.
        let fresh = Driver()
        var t: TimeInterval = 0
        func stepReset(_ label: PoseLabel, _ seconds: TimeInterval) {
            for _ in 0..<Int((seconds * 30).rounded()) {
                used.counter.process(RepCounterFrameInput(
                    timestamp: t, label: label, labelConfidence: 0.9,
                    postureValid: true, requiredJointsConfident: true
                ))
                t += 1.0 / 30.0
            }
        }
        stepReset(.up, 1.0)
        fresh.hold(.up, seconds: 1.0)
        for _ in 0..<2 {
            stepReset(.down, 1.0)
            stepReset(.up, 1.0)
            fresh.cleanRep()
        }
        #expect(used.counter.reps == 2)
        #expect(used.counter.reps == fresh.counter.reps)
        #expect(used.counter.phase == fresh.counter.phase)
        #expect(used.counter.rejectedReps == fresh.counter.rejectedReps)
    }

    @Test("a longer minSecondsBetweenReps rejects reps the default accepts")
    func longerSpacingRejectsMore() {
        func run(_ config: RepCounter.Config) -> (reps: Int, rejected: Int) {
            let driver = Driver(config: config)
            driver.hold(.up, seconds: 1.0)
            for _ in 0..<4 { driver.cleanRep() }  // 2 s per rep
            return (driver.counter.reps, driver.counter.rejectedReps)
        }
        let defaultResult = run(.default)
        #expect(defaultResult.reps == 4)
        #expect(defaultResult.rejected == 0)

        // 3 s minimum with 2 s reps: reps 1 and 3 count (rep 3 is 4 s after
        // rep 1, since a rejected rep does not move the reference), 2 and 4 are rejected.
        let slow = run(RepCounter.Config(minSecondsBetweenReps: 3.0))
        #expect(slow.reps == 2)
        #expect(slow.rejected == 2)
    }

    @Test("an enter threshold above the maximum smoothed confidence never leaves idle")
    func unreachableEnterThreshold() {
        let driver = Driver(config: RepCounter.Config(enterThreshold: 0.95))
        driver.hold(.up, seconds: 1.0)
        driver.cleanRep()
        driver.cleanRep()
        #expect(driver.counter.phase == .idle)
        #expect(driver.counter.reps == 0)
    }

    @Test("a longer minPhaseDuration makes the counter slower to accept a phase")
    func longerDwellDelaysTransitions() {
        // 1 s down / 1 s up cycles: fine at 0.5 s dwell, too fast at 1.5 s.
        func reps(_ config: RepCounter.Config) -> Int {
            let driver = Driver(config: config)
            driver.hold(.up, seconds: 2.0)
            for _ in 0..<4 { driver.cleanRep() }
            return driver.counter.reps
        }
        #expect(reps(.default) == 4)
        #expect(reps(RepCounter.Config(minPhaseDuration: 1.5)) < 4)
    }

    @Test("default Config matches the documented thresholds")
    func defaultConfigValues() {
        let config = RepCounter.Config.default
        #expect(config.emaAlpha == 0.3)
        #expect(config.enterThreshold == 0.6)
        #expect(config.exitThreshold == 0.4)
        #expect(config.minPhaseDuration == 0.5)
        #expect(config.minSecondsBetweenReps == 1.0)
        #expect(RepCounter.requiredJointConfidenceFloor == 0.3)
        #expect(RepCounter.Config() == .default)
    }
}
