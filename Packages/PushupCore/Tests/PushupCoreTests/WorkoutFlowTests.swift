import Foundation
import Testing
import PushupCore
import PushupSynth

/// Feeds `seconds` of constant input at 30 fps starting at `start`, returns
/// the timestamp of the first frame after the run.
@discardableResult
private func hold(
    _ flow: inout WorkoutFlow,
    valid: Bool,
    reps: Int = 0,
    from start: TimeInterval,
    seconds: Double
) -> TimeInterval {
    let frames = Int((seconds * 30).rounded())
    for index in 0..<frames {
        flow.update(postureValid: valid, reps: reps, timestamp: start + Double(index) / 30)
    }
    return start + Double(frames) / 30
}

/// A flow that has already moved to `active` at about t = 1.
private func activeFlow(_ config: WorkoutFlow.Config = .default) -> WorkoutFlow {
    var flow = WorkoutFlow(config: config)
    flow.update(postureValid: true, reps: 0, timestamp: 0)
    flow.update(postureValid: true, reps: 0, timestamp: config.startHold)
    return flow
}

@Suite("WorkoutFlow")
struct WorkoutFlowTests {
    @Test("the default config matches the spec")
    func defaults() {
        let config = WorkoutFlow.Config.default
        #expect(config.startHold == 1.0)
        #expect(config.idleBeforeFinishing == 3.0)
        #expect(config.finishingCountdown == 3.0)
        #expect(config.requiresRepToAutoFinish)
        #expect(WorkoutFlow().phase == .positioning)
    }

    // MARK: - Starting

    @Test("positioning stays put without a valid posture")
    func positioningWithoutPosture() {
        var flow = WorkoutFlow()
        hold(&flow, valid: false, from: 0, seconds: 10)
        #expect(flow.phase == .positioning)
    }

    @Test("the posture must hold for the start time before the flow becomes active")
    func startHold() {
        var flow = WorkoutFlow()
        flow.update(postureValid: true, reps: 0, timestamp: 5.0)
        flow.update(postureValid: true, reps: 0, timestamp: 5.9)
        #expect(flow.phase == .positioning)
        flow.update(postureValid: true, reps: 0, timestamp: 6.0)
        #expect(flow.phase == .active)
    }

    @Test("one invalid frame resets the start hold")
    func invalidFrameResetsHold() {
        var flow = WorkoutFlow()
        flow.update(postureValid: true, reps: 0, timestamp: 0)
        flow.update(postureValid: true, reps: 0, timestamp: 0.9)
        flow.update(postureValid: false, reps: 0, timestamp: 0.95)
        flow.update(postureValid: true, reps: 0, timestamp: 1.0)
        flow.update(postureValid: true, reps: 0, timestamp: 1.9)
        #expect(flow.phase == .positioning)
        flow.update(postureValid: true, reps: 0, timestamp: 2.0)
        #expect(flow.phase == .active)
    }

    @Test("a custom start hold is respected")
    func customStartHold() {
        var flow = WorkoutFlow(config: .init(startHold: 2.5))
        hold(&flow, valid: true, from: 0, seconds: 2.4)
        #expect(flow.phase == .positioning)
        flow.update(postureValid: true, reps: 0, timestamp: 2.5)
        #expect(flow.phase == .active)
    }

    // MARK: - Auto finish

    @Test("with reps, leaving the posture runs the idle wait, then the countdown, then finishes")
    func autoFinish() {
        var flow = activeFlow()
        flow.update(postureValid: false, reps: 4, timestamp: 10)
        flow.update(postureValid: false, reps: 4, timestamp: 12.9)
        #expect(flow.phase == .active)
        flow.update(postureValid: false, reps: 4, timestamp: 13)
        #expect(flow.phase == .finishing(secondsRemaining: 3))
        flow.update(postureValid: false, reps: 4, timestamp: 14)
        #expect(flow.phase == .finishing(secondsRemaining: 2))
        flow.update(postureValid: false, reps: 4, timestamp: 15.5)
        #expect(flow.phase == .finishing(secondsRemaining: 0.5))
        flow.update(postureValid: false, reps: 4, timestamp: 16)
        #expect(flow.phase == .finished)
    }

    @Test("a valid frame inside the idle wait restarts the wait")
    func idleWaitRestarts() {
        var flow = activeFlow()
        flow.update(postureValid: false, reps: 2, timestamp: 10)
        flow.update(postureValid: false, reps: 2, timestamp: 12)
        flow.update(postureValid: true, reps: 2, timestamp: 12.5)
        flow.update(postureValid: false, reps: 2, timestamp: 13)
        flow.update(postureValid: false, reps: 2, timestamp: 15.9)
        #expect(flow.phase == .active)
        flow.update(postureValid: false, reps: 2, timestamp: 16)
        #expect(flow.phase == .finishing(secondsRemaining: 3))
    }

    @Test("a session with zero reps returns to positioning instead of finishing")
    func noAutoFinishWithoutReps() {
        var flow = activeFlow()
        flow.update(postureValid: false, reps: 0, timestamp: 10)
        flow.update(postureValid: false, reps: 0, timestamp: 13)
        #expect(flow.phase == .positioning)
        hold(&flow, valid: false, from: 13, seconds: 30)
        #expect(flow.phase == .positioning)
        // The start hold works again from scratch.
        flow.update(postureValid: true, reps: 0, timestamp: 50)
        #expect(flow.phase == .positioning)
        flow.update(postureValid: true, reps: 0, timestamp: 51)
        #expect(flow.phase == .active)
    }

    @Test("with the rep requirement off, a zero-rep session does auto-finish")
    func optionalRepRequirement() {
        var flow = activeFlow(.init(requiresRepToAutoFinish: false))
        flow.update(postureValid: false, reps: 0, timestamp: 10)
        flow.update(postureValid: false, reps: 0, timestamp: 13)
        #expect(flow.phase == .finishing(secondsRemaining: 3))
        flow.update(postureValid: false, reps: 0, timestamp: 16)
        #expect(flow.phase == .finished)
    }

    @Test("returning to the posture cancels the countdown, and a later exit starts a fresh one")
    func cancelCountdown() {
        var flow = activeFlow()
        flow.update(postureValid: false, reps: 3, timestamp: 10)
        flow.update(postureValid: false, reps: 3, timestamp: 13)
        flow.update(postureValid: false, reps: 3, timestamp: 14.5)
        #expect(flow.phase == .finishing(secondsRemaining: 1.5))
        flow.update(postureValid: true, reps: 3, timestamp: 14.6)
        #expect(flow.phase == .active)
        // Leaving again needs the full idle wait and the full countdown.
        flow.update(postureValid: false, reps: 3, timestamp: 20)
        flow.update(postureValid: false, reps: 3, timestamp: 22.9)
        #expect(flow.phase == .active)
        flow.update(postureValid: false, reps: 3, timestamp: 23)
        #expect(flow.phase == .finishing(secondsRemaining: 3))
    }

    @Test("custom idle and countdown lengths are respected")
    func customTimes() {
        var flow = activeFlow(.init(idleBeforeFinishing: 1, finishingCountdown: 2))
        flow.update(postureValid: false, reps: 1, timestamp: 5)
        flow.update(postureValid: false, reps: 1, timestamp: 6)
        #expect(flow.phase == .finishing(secondsRemaining: 2))
        flow.update(postureValid: false, reps: 1, timestamp: 7)
        #expect(flow.phase == .finishing(secondsRemaining: 1))
        flow.update(postureValid: false, reps: 1, timestamp: 8)
        #expect(flow.phase == .finished)
    }

    // MARK: - Manual finish, terminal state, reset

    @Test("finishNow ends the session from every phase")
    func finishNowFromEachPhase() {
        var positioning = WorkoutFlow()
        positioning.finishNow()
        #expect(positioning.phase == .finished)

        var active = activeFlow()
        #expect(active.phase == .active)
        active.finishNow()
        #expect(active.phase == .finished)

        var finishing = activeFlow()
        finishing.update(postureValid: false, reps: 2, timestamp: 10)
        finishing.update(postureValid: false, reps: 2, timestamp: 13)
        #expect(finishing.phase == .finishing(secondsRemaining: 3))
        finishing.finishNow()
        #expect(finishing.phase == .finished)

        var finished = WorkoutFlow()
        finished.finishNow()
        finished.finishNow()
        #expect(finished.phase == .finished)
    }

    @Test("finished is terminal until reset")
    func finishedIsTerminal() {
        var flow = activeFlow()
        flow.finishNow()
        hold(&flow, valid: true, reps: 5, from: 20, seconds: 5)
        #expect(flow.phase == .finished)
        hold(&flow, valid: false, reps: 5, from: 30, seconds: 10)
        #expect(flow.phase == .finished)

        flow.reset()
        #expect(flow.phase == .positioning)
        hold(&flow, valid: true, from: 100, seconds: 1.1)
        #expect(flow.phase == .active)
    }

    @Test("reset forgets a partial start hold and a running idle wait")
    func resetClearsTimers() {
        var flow = WorkoutFlow()
        flow.update(postureValid: true, reps: 0, timestamp: 0)
        flow.update(postureValid: true, reps: 0, timestamp: 0.9)
        flow.reset()
        flow.update(postureValid: true, reps: 0, timestamp: 1.0)
        #expect(flow.phase == .positioning)

        var active = activeFlow()
        active.update(postureValid: false, reps: 3, timestamp: 10)
        active.update(postureValid: false, reps: 3, timestamp: 12)
        active.reset()
        active.update(postureValid: true, reps: 3, timestamp: 20)
        active.update(postureValid: true, reps: 3, timestamp: 21)
        #expect(active.phase == .active)
        active.update(postureValid: false, reps: 3, timestamp: 22)
        active.update(postureValid: false, reps: 3, timestamp: 24.9)
        #expect(active.phase == .active)
    }

    @Test("identical input gives identical phases")
    func deterministic() {
        func run() -> [WorkoutFlow.Phase] {
            var flow = WorkoutFlow()
            var phases: [WorkoutFlow.Phase] = []
            var time: TimeInterval = 0
            let script: [(Bool, Int, Double)] = [(true, 0, 2), (true, 3, 4), (false, 3, 8), (true, 3, 1), (false, 3, 9)]
            for (valid, reps, seconds) in script {
                for _ in 0..<Int(seconds * 30) {
                    flow.update(postureValid: valid, reps: reps, timestamp: time)
                    phases.append(flow.phase)
                    time += 1.0 / 30
                }
            }
            return phases
        }
        #expect(run() == run())
    }

    // MARK: - With the real pipeline

    @Test("a counted set that ends with the person leaving finishes by itself")
    func endToEnd() {
        let pipeline = PushupPipeline(classifier: HeuristicPoseClassifier())
        var flow = WorkoutFlow()
        var seenFinishing = false
        var reps = 0
        var timestamp: TimeInterval = 0
        for frame in SyntheticPose.repSequence(reps: 3, secondsPerRep: 2.0) {
            let output = pipeline.process(frame)
            reps = output.reps
            timestamp = frame.timestamp
            flow.update(postureValid: output.postureValid, reps: reps, timestamp: timestamp)
        }
        #expect(reps == 3)
        #expect(flow.phase == .active)
        // Then nobody is in frame for 8 seconds.
        for index in 1...240 {
            let frame = PoseFrame(timestamp: timestamp + Double(index) / 30, joints: [:])
            let output = pipeline.process(frame)
            flow.update(postureValid: output.postureValid, reps: output.reps, timestamp: frame.timestamp)
            if case .finishing = flow.phase { seenFinishing = true }
        }
        #expect(seenFinishing)
        #expect(flow.phase == .finished)
    }

    @Test("the first frames of a synthetic set start the flow after the hold")
    func startsFromFrames() {
        let pipeline = PushupPipeline(classifier: HeuristicPoseClassifier())
        var flow = WorkoutFlow()
        var activeAt: TimeInterval?
        for frame in SyntheticPose.repSequence(reps: 1, secondsPerRep: 2.0) {
            let output = pipeline.process(frame)
            flow.update(postureValid: output.postureValid, reps: output.reps, timestamp: frame.timestamp)
            if activeAt == nil, flow.phase == .active { activeAt = frame.timestamp }
        }
        #expect(activeAt == 1.0)
    }
}
