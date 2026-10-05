import CoreGraphics
import Foundation
import Testing
import PushupCore
import PushupSynth

// MARK: - Helpers

private typealias Engine = WorkoutSessionEngine
private let fps = 30.0

/// Frames at the top position (arms straight) for `seconds`.
private func hold(
    _ seconds: Double,
    from start: TimeInterval,
    _ options: SyntheticPose.Options = .foreshortened(),
    elbowDegrees: Double = 165
) -> [PoseFrame] {
    let count = Int((seconds * fps).rounded())
    return (0..<count).map { SyntheticPose.frame(timestamp: start + Double($0) / fps, elbowDegrees: elbowDegrees, options) }
}

/// A press-up set seen from the floor: a held top position, `reps` reps and a held finish.
private func cleanSet(
    reps: Int,
    leadIn: Double = 2.5,
    leadOut: Double = 2,
    secondsPerRep: Double = 2,
    start: TimeInterval = 0,
    _ options: SyntheticPose.Options = .foreshortened()
) -> [PoseFrame] {
    SyntheticPose.repSequence(
        reps: reps, secondsPerRep: secondsPerRep, fps: fps,
        leadInSeconds: leadIn, leadOutSeconds: leadOut, startTime: start, options
    )
}

private func end(of frames: [PoseFrame]) -> TimeInterval {
    (frames.last?.timestamp ?? 0) + 1 / fps
}

/// Arms swinging with the body planted and horizontal: a hands-moving take.
private func swinging(seconds: Double, from start: TimeInterval, swingDegrees: Double = 40) -> [PoseFrame] {
    let count = Int((seconds * fps).rounded())
    return (0..<count).map { i in
        let t = Double(i) / fps
        var options = SyntheticPose.Options.foreshortened()
        options.armSwingDegrees = swingDegrees * sin(2 * .pi * t / 0.8)
        return SyntheticPose.frame(timestamp: start + t, elbowDegrees: 165, options)
    }
}

private func noBody(seconds: Double, from start: TimeInterval) -> [PoseFrame] {
    (0..<Int((seconds * fps).rounded())).map { PoseFrame(timestamp: start + Double($0) / fps, joints: [:]) }
}

@discardableResult
private func run(_ engine: Engine, _ frames: [PoseFrame]) -> [Engine.Output] {
    frames.map { engine.process($0) }
}

private func events(_ outputs: [Engine.Output]) -> [Engine.Event] {
    outputs.flatMap(\.events)
}

private func isFinishing(_ phase: Engine.Phase) -> Bool {
    if case .finishing = phase { return true }
    return false
}

private func started(_ outputs: [Engine.Output]) -> Bool {
    events(outputs).contains(.started)
}

/// A frame with every joint the gates read, wrists at the given places, in a
/// layout that keeps the shoulders level and above the wrists.
private func manualJoints(
    leftWrist: CGPoint = CGPoint(x: 0.4, y: 0.3),
    rightWrist: CGPoint = CGPoint(x: 0.6, y: 0.3),
    shoulders: (CGPoint, CGPoint) = (CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)),
    hips: (CGPoint, CGPoint) = (CGPoint(x: 0.42, y: 0.4), CGPoint(x: 0.58, y: 0.4))
) -> [JointName: JointPoint] {
    func p(_ point: CGPoint) -> JointPoint { JointPoint(x: point.x, y: point.y, confidence: 0.9) }
    return [
        .leftShoulder: p(shoulders.0), .rightShoulder: p(shoulders.1),
        .leftElbow: p(CGPoint(x: 0.35, y: 0.4)), .rightElbow: p(CGPoint(x: 0.65, y: 0.4)),
        .leftWrist: p(leftWrist), .rightWrist: p(rightWrist),
        .leftHip: p(hips.0), .rightHip: p(hips.1),
        .neck: p(CGPoint(x: 0.5, y: 0.5)), .root: p(CGPoint(x: 0.5, y: 0.4)),
    ]
}

// MARK: - Maths

@Suite("Session engine measures")
struct SessionEngineMeasureTests {
    @Test("torso ratio of the synthetic bodies")
    func syntheticRatios() {
        let flat = SyntheticPose.joints(elbowDegrees: 165, .foreshortened())
        let tall = SyntheticPose.joints(elbowDegrees: 165, .upright())
        let aspect = 9.0 / 16.0
        #expect(abs(Double(Engine.torsoRatio(flat, aspect: aspect) ?? 0) - 0.4) < 0.01)
        #expect(abs(Double(Engine.torsoRatio(tall, aspect: aspect) ?? 0) - 1.4) < 0.01)
    }

    @Test("torso ratio corrects x for the image aspect")
    func torsoAspect() {
        let joints = manualJoints()
        // Shoulder width 0.2 and torso length 0.1 in raw units: ratio 0.5 on a square image.
        #expect(abs((Engine.torsoRatio(joints, aspect: 1) ?? 0) - 0.5) < 1e-4)
        // At aspect 0.5 the shoulder width halves to 0.1 while the torso stays vertical: ratio 1.
        #expect(abs((Engine.torsoRatio(joints, aspect: 0.5) ?? 0) - 1.0) < 1e-4)
    }

    @Test("torso ratio is nil without a needed joint or with coincident shoulders")
    func torsoNil() {
        var joints = manualJoints()
        joints[.rightHip] = nil
        #expect(Engine.torsoRatio(joints, aspect: 1) == nil)
        let together = manualJoints(shoulders: (CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)))
        #expect(Engine.torsoRatio(together, aspect: 1) == nil)
    }

    /// One second of frames whose right wrist sits still except for a single frame, number 20,
    /// where it is displaced by `delta`. The median of the window is the resting place.
    private func outlier(delta: CGPoint) -> [PoseFrame] {
        (0..<30).map { i in
            let wrist = i == 20 ? CGPoint(x: 0.6 + delta.x, y: 0.3 + delta.y) : CGPoint(x: 0.6, y: 0.3)
            return PoseFrame(timestamp: Double(i) / fps, joints: manualJoints(rightWrist: wrist))
        }
    }

    @Test("wrist motion is nil until the window holds 0.3 s, then measured")
    func windowFilling() {
        let engine = Engine(config: SessionConfig(imageAspect: 1))
        let outputs = run(engine, outlier(delta: CGPoint(x: 0, y: 0.05)))
        // Frame i is at i / 30 s; 0.3 s of samples first exists at frame 9.
        for output in outputs.prefix(9) { #expect(output.wristMotionRatio == nil) }
        #expect(outputs[9].wristMotionRatio != nil)
    }

    @Test("wrist motion is the largest distance from the median over the median shoulder width")
    func motionValue() throws {
        // The right wrist rests at y 0.3 and once jumps to 0.35: the median is the resting place,
        // the largest distance is 0.05 and the shoulder width is 0.2 (aspect 1), so the ratio is 0.25.
        let engine = Engine(config: SessionConfig(imageAspect: 1))
        let outputs = run(engine, outlier(delta: CGPoint(x: 0, y: 0.05)))
        let ratio = try #require(outputs.last?.wristMotionRatio)
        #expect(abs(ratio - 0.25) < 0.01)
    }

    @Test("wrist motion applies the aspect to x but not to y")
    func motionAspect() throws {
        let config = SessionConfig(imageAspect: 0.5)
        // The same raw jump of 0.1, once along x and once along y.
        let sideways = run(Engine(config: config), outlier(delta: CGPoint(x: 0.1, y: 0)))
        let vertical = run(Engine(config: config), outlier(delta: CGPoint(x: 0, y: 0.1)))
        let x = try #require(sideways.last?.wristMotionRatio)
        let y = try #require(vertical.last?.wristMotionRatio)
        // Shoulder width is 0.1 in iso units. x: 0.1 * 0.5 / 0.1 = 0.5. y: 0.1 / 0.1 = 1.
        #expect(abs(x - 0.5) < 0.01)
        #expect(abs(y - 1.0) < 0.01)
    }

    @Test("a wrist that has stopped moving stops counting once the window has passed")
    func windowForgets() throws {
        let engine = Engine()
        var frames = outlier(delta: CGPoint(x: 0, y: 0.05))
        let still = (0..<45).map { i in PoseFrame(timestamp: 1 + Double(i) / fps, joints: manualJoints(rightWrist: CGPoint(x: 0.6, y: 0.35))) }
        frames += still
        let outputs = run(engine, frames)
        #expect(try #require(outputs[29].wristMotionRatio) > 0.1)
        #expect(try #require(outputs.last?.wristMotionRatio) < 1e-4)
    }

    @Test("wrist motion is nil when a wrist is missing")
    func missingWrist() {
        let engine = Engine()
        var frames = outlier(delta: CGPoint(x: 0, y: 0.05))
        var joints = manualJoints()
        joints[.leftWrist] = nil
        frames.append(PoseFrame(timestamp: 1.0, joints: joints))
        let outputs = run(engine, frames)
        #expect(outputs.last?.wristMotionRatio == nil)
    }

    @Test("rawDepth is DepthTracker's formula")
    func rawDepthMatchesTracker() throws {
        let engine = Engine()
        let pipeline = PushupPipeline(classifier: HeuristicPoseClassifier())
        var tracker = DepthTracker(config: DepthTracker.Config(smoothing: 1))
        var reps = 0
        for degrees in stride(from: 175.0, through: 70.0, by: -7.0) {
            let frame = SyntheticPose.frame(timestamp: 0, elbowDegrees: degrees, .foreshortened())
            let output = pipeline.process(frame)
            _ = tracker.update(with: output, repsBefore: reps)
            reps = output.reps
            let raw = try #require(engine.process(frame).rawDepth)
            #expect(abs(raw - tracker.depth) < 1e-5)
        }
    }

    @Test("the gate failure is the first failing check")
    func gateOrder() {
        let aspect = 9.0 / 16.0
        _ = aspect
        // No joints.
        #expect(Engine().process(PoseFrame(timestamp: 0, joints: [:])).gateFailure == .noBody)
        // Low confidence.
        var options = SyntheticPose.Options.foreshortened()
        options.confidenceOverrides = [.leftWrist: 0.1]
        #expect(Engine().process(SyntheticPose.frame(timestamp: 0, elbowDegrees: 165, options)).gateFailure == .lowConfidence)
        // Wrists above shoulders (legacy geometry) beats the later checks.
        var above = SyntheticPose.Options()
        above.wristsAboveShoulders = true
        #expect(Engine().process(SyntheticPose.frame(timestamp: 0, elbowDegrees: 165, above)).gateFailure == .notInPosture)
        // A tall body that is otherwise in posture.
        #expect(Engine().process(SyntheticPose.frame(timestamp: 0, elbowDegrees: 165, .upright())).gateFailure == .notHorizontal)
        // A good body passes on the first frame (the window is still filling).
        #expect(Engine().process(SyntheticPose.frame(timestamp: 0, elbowDegrees: 165, .foreshortened())).gateFailure == nil)
        // Moving hands on a flat body, once the window has filled.
        let outputs = run(Engine(), swinging(seconds: 1.5, from: 0))
        #expect(outputs.contains { $0.gateFailure == .handsMoving })
    }
}

// MARK: - Counting

@Suite("Session engine counting")
struct SessionEngineCountingTests {
    @Test("a clean set after a held top position counts exactly N", arguments: [1, 2, 3, 5, 8, 12])
    func cleanSetCounts(reps: Int) {
        let engine = Engine()
        let outputs = run(engine, cleanSet(reps: reps))
        #expect(started(outputs))
        #expect(engine.reps == reps)
        #expect(outputs.last?.phase == .active)
        #expect(engine.repTimes.count == reps)
        #expect(zip(engine.repTimes, engine.repTimes.dropFirst()).allSatisfy { $0 < $1 })
        let counted = events(outputs).compactMap { event -> Int? in
            if case .repCounted(let n) = event { return n }
            return nil
        }
        #expect(counted == Array(1...reps))
    }

    @Test("nothing is counted during positioning")
    func nothingWhilePositioning() {
        // Reps start right away, before the hold can complete: the early ones are not counted.
        let engine = Engine()
        let outputs = run(engine, cleanSet(reps: 3, leadIn: 0, leadOut: 2))
        for output in outputs where output.phase == .positioning { #expect(output.reps == 0 && output.pipeline == nil) }
        #expect(engine.reps <= 3)
    }

    @Test("an approach, then a held top position, then N reps counts exactly N, never N plus 1", arguments: [1, 3, 5, 8])
    func approachThenReps(reps: Int) {
        var frames = SyntheticPose.approachSequence(seconds: 2.5)
        frames += cleanSet(reps: reps, leadIn: 3, leadOut: 2, start: end(of: frames))
        let engine = Engine()
        let outputs = run(engine, frames)
        #expect(started(outputs))
        #expect(engine.reps == reps)
        // Not one rep before the held position.
        let first = outputs.firstIndex { $0.reps > 0 }
        #expect((first.map { frames[$0].timestamp } ?? 99) > 2.5 + 3)
    }

    @Test("an arm wave never leaves positioning and counts 0, but the legacy config counts it")
    func armWave() throws {
        let frames = SyntheticPose.armWaveSequence(seconds: 14)
        let engine = Engine()
        let outputs = run(engine, frames)
        #expect(!started(outputs))
        #expect(outputs.allSatisfy { $0.phase == .positioning && $0.reps == 0 })
        #expect(engine.reps == 0)
        // The sequence really is an arm wave: the wrists move more than a shoulder width, the
        // body is tall and the elbows bend fully.
        #expect(try #require(outputs.compactMap(\.wristMotionRatio).max()) > 1.0)
        #expect(try #require(outputs.compactMap(\.torsoRatio).min()) > 1.3)
        #expect(try #require(outputs.compactMap(\.rawDepth).max()) == 1)

        let legacy = Engine(config: .legacy)
        run(legacy, frames)
        #expect(legacy.reps > 0)
    }

    @Test("a planted, horizontal body whose elbows never straighten does not start")
    func bentArmsDoNotStart() {
        let frames = hold(6, from: 0, elbowDegrees: 105)
        let engine = Engine()
        let outputs = run(engine, frames)
        #expect(!started(outputs))
        #expect(outputs.allSatisfy { $0.gateFailure == nil })
        #expect(outputs.last?.hint == .holdTheTop)

        var relaxed = SessionConfig.default
        relaxed.startRequiresStraightArms = false
        #expect(started(run(Engine(config: relaxed), frames)))
    }

    @Test("the start hold is reported as progress and resets on a bad frame")
    func holdProgress() throws {
        let engine = Engine()
        var frames = hold(0.5, from: 0)
        frames += noBody(seconds: 0.1, from: 0.5)
        frames += hold(1.5, from: 0.6)
        let outputs = run(engine, frames)
        let beforeBreak = try #require(outputs[14].holdProgress as Double?)
        #expect(beforeBreak > 0.4 && beforeBreak < 0.6)
        #expect(outputs[16].holdProgress == 0)
        #expect(outputs.first { $0.events.contains(.started) }.map { $0.holdProgress } == 0)
        // The hold had to start again after the break, so the start is at least 1 s after it.
        let startIndex = try #require(outputs.firstIndex { $0.events.contains(.started) })
        #expect(frames[startIndex].timestamp >= 0.6 + 1.0 - 0.01)
    }

    @Test("a take starts, and the start time and rep times are on the frame timeline")
    func timeline() throws {
        let engine = Engine()
        let frames = cleanSet(reps: 3, start: 10)
        run(engine, frames)
        let start = try #require(engine.activeStartTimestamp)
        #expect(start >= 10 + 1.0 - 0.01 && start < 10 + 1.2)
        #expect(engine.repTimes.allSatisfy { $0 > start })
    }
}

// MARK: - Gates can be switched off

@Suite("Session engine gates")
struct SessionEngineGateSwitchTests {
    private func canStart(_ frames: [PoseFrame], _ config: SessionConfig) -> Bool {
        started(run(Engine(config: config), frames))
    }

    @Test("a tall body with planted hands is blocked by the horizontal-body gate only")
    func horizontalGate() {
        var tall = SyntheticPose.Options.upright()
        tall.plant = 1
        let frames = hold(4, from: 0, tall)
        #expect(!canStart(frames, .default))
        var config = SessionConfig.default
        config.horizontalBodyGate = false
        #expect(canStart(frames, config))
    }

    @Test("a flat body with moving hands is blocked by the planted-hands gate only")
    func plantedGate() {
        let frames = swinging(seconds: 5, from: 0)
        #expect(!canStart(frames, .default))
        var config = SessionConfig.default
        config.plantedHandsGate = false
        #expect(canStart(frames, config))
    }

    @Test("each gate blocks on its own, and with both off the arm wave still needs straight arms or not")
    func independence() {
        let wave = SyntheticPose.armWaveSequence(seconds: 8)
        var noHorizontal = SessionConfig.default
        noHorizontal.horizontalBodyGate = false
        #expect(!canStart(wave, noHorizontal))
        var noPlanted = SessionConfig.default
        noPlanted.plantedHandsGate = false
        #expect(!canStart(wave, noPlanted))
        var neither = noPlanted
        neither.horizontalBodyGate = false
        neither.startRequiresStraightArms = false
        #expect(canStart(wave, neither))
    }

    @Test("a gate that is off never reports its failure")
    func offGateNeverReported() {
        var config = SessionConfig.default
        config.horizontalBodyGate = false
        config.plantedHandsGate = false
        let outputs = run(Engine(config: config), SyntheticPose.armWaveSequence(seconds: 5))
        #expect(outputs.allSatisfy { $0.gateFailure != .notHorizontal && $0.gateFailure != .handsMoving })
    }
}

// MARK: - Ending

@Suite("Session engine ending")
struct SessionEngineEndingTests {
    /// Two reps, a held top, and then `tail` frames from a closure.
    private func twoRepsThen(_ tail: (TimeInterval) -> [PoseFrame]) -> (frames: [PoseFrame], liftTime: TimeInterval) {
        var frames = cleanSet(reps: 2, leadIn: 2.5, leadOut: 1.5)
        let liftTime = end(of: frames)
        frames += tail(liftTime)
        return (frames, liftTime)
    }

    private func lifted(_ seconds: Double, from start: TimeInterval) -> [PoseFrame] {
        var options = SyntheticPose.Options.foreshortened()
        options.rightWristOffset = CGPoint(x: 0, y: 0.45)
        return hold(seconds, from: start, options)
    }

    @Test("lifting one hand ends the set through finishing within leaveHold plus the countdown")
    func liftEnds() throws {
        let config = SessionConfig.default
        let (frames, lift) = twoRepsThen { lifted(5, from: $0) }
        let engine = Engine()
        let outputs = run(engine, frames)
        #expect(engine.reps == 2)
        let beganIndex = try #require(outputs.firstIndex { $0.events.contains(.finishingBegan) })
        let finishedIndex = try #require(outputs.firstIndex { $0.events.contains(.finished) })
        let slack = 3 / fps
        #expect(frames[beganIndex].timestamp - lift <= config.leaveHold + slack)
        #expect(frames[finishedIndex].timestamp - lift <= config.leaveHold + config.finishingCountdown + slack)
        #expect(outputs.last?.phase == .finished)
        #expect(outputs.last?.reps == 2)
        // Nothing is counted while finishing.
        #expect(outputs[beganIndex...].allSatisfy { $0.reps == 2 })
    }

    @Test("returning to the top position within the countdown resumes")
    func liftThenReturn() {
        let (frames, _) = twoRepsThen { start in
            let up = lifted(0.6, from: start)
            return up + hold(4, from: end(of: up))
        }
        let engine = Engine()
        let outputs = run(engine, frames)
        let all = events(outputs)
        #expect(all.contains(.finishingBegan))
        #expect(all.contains(.resumed))
        #expect(!all.contains(.finished))
        #expect(outputs.last?.phase == .active)
        #expect(engine.reps == 2)
    }

    @Test("reps counted after resuming still add to the count")
    func repsAfterResume() {
        let (frames, _) = twoRepsThen { start in
            let up = lifted(0.6, from: start)
            let rest = hold(2.5, from: end(of: up))
            return up + rest + cleanSet(reps: 2, leadIn: 0, leadOut: 2, start: end(of: up + rest))
        }
        let engine = Engine()
        run(engine, frames)
        #expect(engine.reps == 4)
    }

    @Test("leaving the frame ends the set after the idle time and the countdown")
    func leavingTheFrame() throws {
        let (frames, gone) = twoRepsThen { noBody(seconds: 5, from: $0) }
        let config = SessionConfig.default
        let outputs = run(Engine(), frames)
        let began = try #require(outputs.firstIndex { $0.events.contains(.finishingBegan) })
        let finished = try #require(outputs.firstIndex { $0.events.contains(.finished) })
        let slack = 2 / fps
        #expect(abs(frames[began].timestamp - gone - config.idleBeforeFinishing) < slack)
        #expect(abs(frames[finished].timestamp - frames[began].timestamp - config.finishingCountdown) < slack)
    }

    @Test("the countdown value falls from the full countdown")
    func countdownValues() {
        let (frames, _) = twoRepsThen { noBody(seconds: 5, from: $0) }
        let outputs = run(Engine(), frames)
        let remaining = outputs.compactMap { output -> Double? in
            if case .finishing(let seconds) = output.phase { return seconds }
            return nil
        }
        #expect(remaining.first == SessionConfig.default.finishingCountdown)
        #expect(zip(remaining, remaining.dropFirst()).allSatisfy { $0 > $1 })
        #expect(remaining.allSatisfy { $0 > 0 })
    }

    @Test("autoFinish off never ends the set by itself")
    func autoFinishOff() {
        var config = SessionConfig.default
        config.autoFinish = false
        let (frames, _) = twoRepsThen { noBody(seconds: 8, from: $0) }
        let outputs = run(Engine(config: config), frames)
        #expect(outputs.last?.phase == .active)
        #expect(!events(outputs).contains(.finishingBegan))
    }

    @Test("zero reps never auto-finishes: the set goes back to positioning")
    func zeroRepsReturnToPositioning() throws {
        var frames = hold(3, from: 0)
        frames += noBody(seconds: 4, from: end(of: frames))
        let engine = Engine()
        let outputs = run(engine, frames)
        #expect(started(outputs))
        let all = events(outputs)
        #expect(!all.contains(.finishingBegan) && !all.contains(.finished))
        #expect(outputs.last?.phase == .positioning)
        #expect(outputs.last?.holdProgress == 0)
        #expect(engine.activeStartTimestamp == nil)

        // The same with a lifted hand instead of leaving the frame.
        var options = SyntheticPose.Options.foreshortened()
        options.rightWristOffset = CGPoint(x: 0, y: 0.45)
        let lifted = hold(3, from: 0) + hold(4, from: 3, options)
        let second = run(Engine(), lifted)
        #expect(!events(second).contains(.finishingBegan))
        #expect(second.last?.phase == .positioning)
    }

    @Test("with requiresRepToAutoFinish off, a zero-rep set does finish")
    func zeroRepsMayFinish() {
        var config = SessionConfig.default
        config.requiresRepToAutoFinish = false
        let frames = hold(3, from: 0) + noBody(seconds: 5, from: 3)
        let outputs = run(Engine(config: config), frames)
        #expect(events(outputs).contains(.finished))
    }
}

@Suite("Session engine finish and reset")
struct SessionEngineFinishTests {
    @Test("finishNow works from positioning, active and finishing, and reports finished once")
    func finishNowEverywhere() {
        // Positioning.
        let positioning = Engine()
        positioning.process(hold(0.2, from: 0)[0])
        positioning.finishNow()
        #expect(positioning.phase == .finished)
        let reported = positioning.process(hold(0.1, from: 1)[0])
        #expect(reported.phase == .finished)
        #expect(reported.events == [.finished])
        #expect(positioning.process(hold(0.1, from: 1.1)[0]).events.isEmpty)

        // Active.
        let active = Engine()
        run(active, cleanSet(reps: 2))
        #expect(active.phase == .active)
        active.finishNow()
        #expect(active.process(hold(0.1, from: 100)[0]).events == [.finished])
        #expect(active.reps == 2)

        // Finishing.
        let finishing = Engine()
        let frames = cleanSet(reps: 2) + noBody(seconds: 1.3, from: 20)
        run(finishing, frames)
        #expect(isFinishing(finishing.phase))
        finishing.finishNow()
        #expect(finishing.process(PoseFrame(timestamp: 30, joints: [:])).events == [.finished])
    }

    @Test("finished is terminal until reset")
    func finishedIsTerminal() {
        let engine = Engine()
        run(engine, cleanSet(reps: 3))
        engine.finishNow()
        engine.process(PoseFrame(timestamp: 50, joints: [:]))
        let later = run(engine, cleanSet(reps: 2, start: 51))
        #expect(later.allSatisfy { $0.phase == .finished && $0.events.isEmpty && $0.hint == nil })
        #expect(engine.reps == 3)

        engine.reset()
        #expect(engine.phase == .positioning)
        #expect(engine.reps == 0 && engine.repTimes.isEmpty && engine.activeStartTimestamp == nil)
        let again = run(engine, cleanSet(reps: 2, start: 100))
        #expect(started(again))
        #expect(engine.reps == 2)
    }

    @Test("finishNow after the countdown finished does not report a second time")
    func noDoubleFinish() {
        let engine = Engine()
        let frames = cleanSet(reps: 2) + noBody(seconds: 5, from: 20)
        let outputs = run(engine, frames)
        #expect(events(outputs).filter { $0 == .finished }.count == 1)
        engine.finishNow()
        #expect(engine.process(PoseFrame(timestamp: 40, joints: [:])).events.isEmpty)
    }
}

// MARK: - Hints

@Suite("Session engine hints")
struct SessionEngineHintTests {
    /// The hint on the last frame before 0.55 s and on the last frame after 0.7 s of the same condition.
    private func hints(_ frames: [PoseFrame], config: SessionConfig = .default) -> (early: Engine.Hint?, late: Engine.Hint?) {
        let outputs = run(Engine(config: config), frames)
        return (outputs[Int(0.5 * fps)].hint, outputs[Int(0.75 * fps)].hint)
    }

    private func frames(_ options: SyntheticPose.Options, elbow: Double = 165) -> [PoseFrame] {
        hold(1, from: 0, options, elbowDegrees: elbow)
    }

    @Test("each failure maps to its hint, only after 0.6 s")
    func positioningMapping() {
        var lowConfidence = SyntheticPose.Options.foreshortened()
        lowConfidence.confidenceOverrides = [.leftWrist: 0.1]
        var notInPosture = SyntheticPose.Options()
        notInPosture.wristsAboveShoulders = true

        let cases: [(String, [PoseFrame], Engine.Hint)] = [
            ("noBody", noBody(seconds: 1, from: 0), .stepBack),
            ("lowConfidence", frames(lowConfidence), .cannotSeeArms),
            ("notInPosture", frames(notInPosture), .handsOnFloor),
            ("notHorizontal", frames(.upright()), .handsOnFloor),
            ("handsMoving", swinging(seconds: 1.5, from: 0), .handsOnFloor),
            ("holdTheTop", frames(.foreshortened(), elbow: 100), .holdTheTop),
        ]
        for (name, input, expected) in cases {
            let result: (early: Engine.Hint?, late: Engine.Hint?)
            if name == "handsMoving" {
                // The window needs 0.3 s before it can fail, so look later.
                let outputs = run(Engine(), input)
                result = (outputs[Int(0.5 * fps)].hint, outputs[Int(1.4 * fps)].hint)
            } else {
                result = hints(input)
            }
            #expect(result.early == nil, "\(name) must not show before 0.6 s")
            #expect(result.late == expected, "\(name)")
        }
    }

    @Test("no hint while the hold is progressing")
    func noHintWhileHolding() {
        let outputs = run(Engine(), hold(0.9, from: 0))
        #expect(outputs.allSatisfy { $0.hint == nil })
    }

    @Test("while active the same mapping holds, and goLower follows a shallow attempt")
    func activeHints() throws {
        // A person who started and then steps out of view for 0.8 s.
        let engine = Engine()
        let setup = cleanSet(reps: 2, leadOut: 1.5)
        run(engine, setup)
        let gone = run(engine, noBody(seconds: 0.8, from: end(of: setup)))
        #expect(gone[Int(0.3 * fps)].hint == nil)
        #expect(gone.last?.hint == .stepBack)
        #expect(gone.last?.phase == .active)

        // A half rep: bends but never reaches the counting depth.
        let shallow = Engine()
        let frames = hold(1.5, from: 0)
            + SyntheticPose.repSequence(
                reps: 1, secondsPerRep: 2, fps: fps, bottomDegrees: 135,
                leadInSeconds: 0, leadOutSeconds: 3, startTime: 1.5, .foreshortened()
            )
        let outputs = run(shallow, frames)
        let attempt = try #require(outputs.firstIndex { output in
            output.events.contains { if case .shallowAttempt = $0 { return true } else { return false } }
        })
        #expect(shallow.shallowAttempts == 1)
        #expect(outputs[attempt].hint == .goLower)
        let tAttempt = frames[attempt].timestamp
        // Still showing about a second after, gone after 1.2 s.
        let during = try #require(frames.firstIndex { $0.timestamp >= tAttempt + 1.0 })
        #expect(outputs[during].hint == .goLower)
        let after = try #require(frames.firstIndex { $0.timestamp > tAttempt + 1.25 })
        #expect(outputs[after].hint != .goLower)
    }

    @Test("no hints while finishing or finished")
    func noHintsWhenEnding() {
        let engine = Engine()
        let frames = cleanSet(reps: 2) + noBody(seconds: 5, from: 20)
        let outputs = run(engine, frames)
        for output in outputs {
            switch output.phase {
            case .finishing, .finished: #expect(output.hint == nil)
            default: break
            }
        }
        #expect(outputs.contains { isFinishing($0.phase) })
    }
}

// MARK: - Legacy, decoding, determinism

@Suite("Session engine legacy equivalence")
struct SessionEngineLegacyTests {
    private static let sequences: [(String, [PoseFrame])] = [
        ("clean 6", SyntheticPose.repSequence(reps: 6, secondsPerRep: 2, fps: 30, leadInSeconds: 2, leadOutSeconds: 2)),
        ("fast 8", SyntheticPose.repSequence(reps: 8, secondsPerRep: 1.5, fps: 30, leadInSeconds: 1.5, leadOutSeconds: 2)),
        ("half reps", SyntheticPose.repSequence(reps: 5, secondsPerRep: 2, fps: 30, bottomDegrees: 135, leadInSeconds: 2, leadOutSeconds: 1)),
        ("slow 4", SyntheticPose.repSequence(reps: 4, secondsPerRep: 4, fps: 30, leadInSeconds: 1.2, leadOutSeconds: 2)),
    ]

    @Test("the legacy config counts what a bare pipeline counts from the moment it becomes active", arguments: sequences.map(\.0))
    func matchesBarePipeline(name: String) throws {
        let frames = try #require(Self.sequences.first { $0.0 == name }?.1)
        let engine = Engine(config: .legacy)
        let outputs = run(engine, frames)
        let startIndex = try #require(outputs.firstIndex { $0.events.contains(.started) })

        let pipeline = PipelineConfig.default.makePipeline()
        var bareTimes: [TimeInterval] = []
        var bareReps = 0
        for frame in frames[(startIndex + 1)...] {
            let output = pipeline.process(frame)
            if output.reps > bareReps { bareTimes.append(frame.timestamp) }
            bareReps = output.reps
        }
        #expect(engine.reps == bareReps)
        #expect(engine.repTimes == bareTimes)
        #expect(engine.rejectedReps >= 0)
    }

    @Test("the legacy config switches off exactly the three new checks")
    func legacyShape() {
        var expected = SessionConfig.default
        expected.plantedHandsGate = false
        expected.horizontalBodyGate = false
        expected.startRequiresStraightArms = false
        #expect(SessionConfig.legacy == expected)
    }
}

@Suite("Session config")
struct SessionConfigTests {
    @Test("defaults")
    func defaults() {
        let config = SessionConfig.default
        #expect(config.imageAspect == 9.0 / 16.0)
        #expect(config.startHold == 1.0 && config.startRequiresStraightArms && config.straightArmsMaxDepth == 0.2)
        #expect(config.plantedHandsGate && config.plantedHandsWindow == 0.6 && config.plantedHandsMaxMotion == 0.35)
        #expect(config.horizontalBodyGate && config.horizontalBodyMaxTorsoRatio == 0.9)
        #expect(config.autoFinish && config.leaveHandsMotion == 0.5 && config.leaveHold == 0.3)
        #expect(config.idleBeforeFinishing == 1.0 && config.finishingCountdown == 2.0 && config.resumeHold == 0.3)
        #expect(config.requiresRepToAutoFinish)
        #expect(config.nonDefaultDescription.isEmpty)
    }

    @Test("an empty object is the default config")
    func emptyObject() throws {
        #expect(try JSONDecoder().decode(SessionConfig.self, from: Data("{}".utf8)) == .default)
        #expect(try JSONDecoder().decode(SessionConfig.self, from: Data(#"{"pipeline": {}, "depth": {}}"#.utf8)) == .default)
    }

    @Test("one overridden key changes only that key")
    func singleOverride() throws {
        let config = try JSONDecoder().decode(SessionConfig.self, from: Data(#"{"plantedHandsMaxMotion": 0.6}"#.utf8))
        var expected = SessionConfig.default
        expected.plantedHandsMaxMotion = 0.6
        #expect(config == expected)
        #expect(config.nonDefaultDescription == ["plantedHandsMaxMotion = 0.6"])

        let nested = try JSONDecoder().decode(SessionConfig.self, from: Data(#"{"pipeline": {"repCounter": {"emaAlpha": 0.5}}}"#.utf8))
        var expectedNested = SessionConfig.default
        expectedNested.pipeline.repCounter.emaAlpha = 0.5
        #expect(nested == expectedNested)
    }

    @Test("a config survives an encode and decode round trip")
    func roundTrip() throws {
        for config in [SessionConfig.default, .legacy] {
            let data = try JSONEncoder().encode(config)
            #expect(try JSONDecoder().decode(SessionConfig.self, from: data) == config)
        }
    }

    @Test("the depth tracker config decodes tolerantly")
    func depthConfig() throws {
        let config = try JSONDecoder().decode(DepthTracker.Config.self, from: Data(#"{"smoothing": 1}"#.utf8))
        var expected = DepthTracker.Config.default
        expected.smoothing = 1
        #expect(config == expected)
    }

    @Test("a config reaches the engine")
    func reachesEngine() {
        var config = SessionConfig.default
        config.startHold = 30
        #expect(!started(run(Engine(config: config), cleanSet(reps: 2))))
        #expect(Engine(config: config).config.startHold == 30)
    }
}

@Suite("Session engine determinism")
struct SessionEngineDeterminismTests {
    private func signature(_ outputs: [Engine.Output]) -> [String] {
        outputs.map { o in
            "\(o.phase)|\(o.reps)|\(o.depth)|\(o.holdProgress)|\(String(describing: o.hint))|\(o.events)|\(o.shallowAttempts)|"
                + "\(String(describing: o.gateFailure))|\(String(describing: o.wristMotionRatio))|\(String(describing: o.torsoRatio))|\(String(describing: o.rawDepth))"
        }
    }

    @Test("identical input gives identical output, across engines and after reset")
    func repeatable() {
        var frames = SyntheticPose.approachSequence(seconds: 2.5)
        frames += cleanSet(reps: 4, leadIn: 3, leadOut: 1.5, start: end(of: frames))
        frames += noBody(seconds: 4, from: end(of: frames))
        let first = Engine()
        let a = signature(run(first, frames))
        let b = signature(run(Engine(), frames))
        first.reset()
        let c = signature(run(first, frames))
        #expect(a == b)
        #expect(a == c)
        #expect(!a.isEmpty)
    }
}

// MARK: - Real recording

@Suite("Session engine on a real recording")
struct SessionEngineRealTakeTests {
    private func load() throws -> RecordedSession {
        let url = try #require(Bundle.module.url(forResource: "real_take_4reps", withExtension: "json", subdirectory: "Fixtures"))
        return try RecordedSession.load(from: url)
    }

    @Test("the default config counts the 4 press-ups of a real take, and no frame is gated")
    func realTake() throws {
        let session = try load()
        #expect(session.trueReps == 4)
        let engine = Engine()
        let outputs = run(engine, session.poseFrames())
        #expect(started(outputs))
        #expect(engine.reps == 4)
        #expect(outputs.last?.phase == .active)
        // Observed on this take with the first-guess thresholds: every frame passes.
        #expect(outputs.allSatisfy { $0.gateFailure == nil })
        // The torso ratio of this take stays below the 0.9 threshold, with some room.
        #expect((outputs.compactMap(\.torsoRatio).max() ?? 9) < 0.9)
    }

    @Test("the legacy config counts the same take the same way")
    func realTakeLegacy() throws {
        let engine = Engine(config: .legacy)
        run(engine, try load().poseFrames())
        #expect(engine.reps == 4)
    }
}
