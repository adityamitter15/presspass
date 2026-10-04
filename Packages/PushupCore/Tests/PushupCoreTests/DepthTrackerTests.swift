import Foundation
import Testing
import PushupCore
import PushupSynth

/// One tracker update per pipeline frame, with `repsBefore` taken from the
/// previous output, the way the workout screen drives it.
private struct Driver {
    let pipeline = PushupPipeline(classifier: HeuristicPoseClassifier())
    var tracker: DepthTracker
    var reps = 0
    var events: [DepthTracker.Event] = []
    var depths: [Float] = []
    var lastOutput: PipelineOutput?

    init(config: DepthTracker.Config = .default) {
        tracker = DepthTracker(config: config)
    }

    mutating func feed(_ frames: [PoseFrame]) {
        for frame in frames {
            let output = pipeline.process(frame)
            events.append(tracker.update(with: output, repsBefore: reps))
            depths.append(tracker.depth)
            reps = output.reps
            lastOutput = output
        }
    }

    var attempts: [Float] {
        events.compactMap { event in
            if case .shallowAttempt(let peak) = event { return peak }
            return nil
        }
    }
}

private func constant(elbowDegrees: Double, count: Int = 1, _ options: SyntheticPose.Options = .init()) -> [PoseFrame] {
    (0..<count).map { SyntheticPose.frame(timestamp: Double($0) / 30, elbowDegrees: elbowDegrees, options) }
}

private let unsmoothed = DepthTracker.Config(smoothing: 1)

@Suite("DepthTracker")
struct DepthTrackerTests {
    @Test("the default config reads the heuristic classifier's thresholds")
    func defaults() {
        let config = DepthTracker.Config.default
        #expect(config.upElbowDegrees == HeuristicPoseClassifier.Config.default.upElbowDegrees)
        #expect(config.downElbowDegrees == HeuristicPoseClassifier.Config.default.downElbowDegrees)
        #expect(config.smoothing == 0.5)
        #expect(config.shallowMinDepth == 0.35)
        #expect(config.returnDepth == 0.15)
    }

    @Test("a fresh tracker sits at depth 0")
    func initialState() {
        let tracker = DepthTracker()
        #expect(tracker.depth == 0)
        #expect(tracker.peakDepthThisDescent == 0)
    }

    // MARK: - Depth mapping

    @Test("depth is 0 with straight arms and 1 at and below the down threshold", arguments: [
        (165.0, 0.0), (150.0, 0.0), (145.0, 0.0), (120.0, 1.0), (100.0, 1.0), (80.0, 1.0),
    ] as [(Double, Double)])
    func endpoints(degrees: Double, expected: Double) {
        var driver = Driver(config: unsmoothed)
        driver.feed(constant(elbowDegrees: degrees))
        #expect(abs(Double(driver.tracker.depth) - expected) < 0.01)
    }

    @Test("depth rises monotonically as the elbow closes from the up to the down threshold")
    func monotonic() {
        let angles = stride(from: 150.0, through: 115.0, by: -2.5).map { $0 }
        var previous: Float = -1
        for degrees in angles {
            var driver = Driver(config: unsmoothed)
            driver.feed(constant(elbowDegrees: degrees))
            let depth = driver.tracker.depth
            #expect(depth >= previous)
            #expect((0...1).contains(depth))
            previous = depth
        }
        var mid = Driver(config: unsmoothed)
        mid.feed(constant(elbowDegrees: 132.5))
        #expect(abs(mid.tracker.depth - 0.5) < 0.02)
    }

    @Test("custom thresholds move the mapping")
    func customThresholds() {
        var driver = Driver(config: DepthTracker.Config(upElbowDegrees: 160, downElbowDegrees: 100, smoothing: 1))
        driver.feed(constant(elbowDegrees: 130))
        #expect(abs(driver.tracker.depth - 0.5) < 0.02)
    }

    // MARK: - Smoothing and decay

    @Test("depth approaches the raw value through the EMA")
    func smoothing() {
        var driver = Driver()
        driver.feed(constant(elbowDegrees: 100, count: 3))
        #expect(abs(driver.depths[0] - 0.5) < 0.01)
        #expect(abs(driver.depths[1] - 0.75) < 0.01)
        #expect(abs(driver.depths[2] - 0.875) < 0.01)

        var slow = Driver(config: DepthTracker.Config(smoothing: 0.2))
        slow.feed(constant(elbowDegrees: 100, count: 2))
        #expect(abs(slow.depths[0] - 0.2) < 0.01)
        #expect(abs(slow.depths[1] - 0.36) < 0.01)
    }

    @Test("depth decays towards 0 when the frame has no features")
    func decayWithoutFeatures() throws {
        var driver = Driver()
        driver.feed(constant(elbowDegrees: 100, count: 6))
        let before = driver.tracker.depth
        #expect(before > 0.9)
        driver.feed([PoseFrame(timestamp: 1, joints: [:])])
        let output = try #require(driver.lastOutput)
        #expect(output.features == nil)
        #expect(abs(driver.tracker.depth - before / 2) < 0.01)
        driver.feed((0..<10).map { _ in PoseFrame(timestamp: 1, joints: [:]) })
        #expect(driver.tracker.depth < 0.01)
        #expect(driver.attempts.isEmpty)
    }

    @Test("depth decays and no event fires when the posture gate fails")
    func decayOnBadPosture() throws {
        var options = SyntheticPose.Options()
        options.wristsAboveShoulders = true
        var driver = Driver()
        driver.feed(constant(elbowDegrees: 128, count: 20))
        let before = driver.tracker.depth
        #expect(before > 0.5)
        driver.feed(constant(elbowDegrees: 128, count: 20, options))
        let output = try #require(driver.lastOutput)
        #expect(output.features != nil)
        #expect(!output.postureValid)
        #expect(driver.tracker.depth < 0.01)
        #expect(driver.attempts.isEmpty)
        #expect(driver.events.allSatisfy { $0 == .none })
    }

    // MARK: - Descents and shallow attempts

    @Test("a full counted rep emits no shallow event", arguments: [1, 3, 8])
    func fullRepsAreNotShallow(_ reps: Int) {
        var driver = Driver()
        driver.feed(SyntheticPose.repSequence(reps: reps, secondsPerRep: 2.0))
        #expect(driver.reps == reps)
        #expect(driver.events.allSatisfy { $0 == .none })
        #expect((driver.depths.max() ?? 0) > 0.95)
    }

    @Test("a full rep is not reported as shallow even if the counter credits it after the descent has ended")
    func lateCreditNotShallow() {
        let pipeline = PushupPipeline(classifier: HeuristicPoseClassifier())
        var tracker = DepthTracker()
        var reps = 0
        var peakIndex = 0
        var peak: Float = 0
        var descentEndIndex: Int?
        var creditIndex: Int?
        for (index, frame) in SyntheticPose.repSequence(reps: 1, secondsPerRep: 2.0).enumerated() {
            let output = pipeline.process(frame)
            #expect(tracker.update(with: output, repsBefore: reps) == .none)
            if tracker.depth > peak { peak = tracker.depth; peakIndex = index }
            if peak > 0.9, index > peakIndex, descentEndIndex == nil, tracker.depth < 0.15 { descentEndIndex = index }
            if output.reps > reps { creditIndex = index }
            reps = output.reps
        }
        #expect(reps == 1)
        let end = descentEndIndex
        let credit = creditIndex
        #expect(end != nil && credit != nil)
        // The depth signal settles back before (or as) the counter credits the
        // rep, which is why the tracker must not call that descent shallow.
        if let end, let credit { #expect(end <= credit) }
    }

    @Test("a rep count increase during the descent suppresses the event")
    func repCountSuppresses() {
        // A shallow descent on its own is reported. Telling the tracker that
        // the count went up part way through (repsBefore below output.reps)
        // must silence it, whatever the depth.
        let frames = SyntheticPose.repSequence(reps: 1, secondsPerRep: 2.0, bottomDegrees: 130)

        var plain = Driver()
        plain.feed(frames)
        #expect(plain.attempts.count == 1)

        let pipeline = PushupPipeline(classifier: HeuristicPoseClassifier())
        var tracker = DepthTracker()
        var events: [DepthTracker.Event] = []
        for (index, frame) in frames.enumerated() {
            let output = pipeline.process(frame)
            // Pretend the counter ticked up on frame 60, the bottom.
            let before = index == 60 ? output.reps - 1 : output.reps
            events.append(tracker.update(with: output, repsBefore: before))
        }
        #expect(tracker.peakDepthThisDescent == 0)
        #expect(events.allSatisfy { $0 == .none })
    }

    @Test("a descent that peaks between the shallow minimum and full depth emits exactly one shallow attempt",
          arguments: [125.0, 130.0, 135.0])
    func shallowAttempt(bottom: Double) throws {
        var driver = Driver()
        driver.feed(SyntheticPose.repSequence(reps: 1, secondsPerRep: 2.0, bottomDegrees: bottom))
        #expect(driver.reps == 0)
        let peak = try #require(driver.attempts.first)
        #expect(driver.attempts.count == 1)
        #expect(peak >= 0.35)
        #expect(peak < 1)
        // The event lands once the person is back up, not at the peak.
        #expect(driver.events.last.map { $0 == .none } == true)
        #expect(driver.tracker.peakDepthThisDescent == 0)
    }

    @Test("every shallow rep in a set is reported once")
    func repeatedShallowAttempts() {
        var driver = Driver()
        driver.feed(SyntheticPose.repSequence(reps: 4, secondsPerRep: 2.0, bottomDegrees: 133))
        #expect(driver.reps == 0)
        #expect(driver.attempts.count == 4)
    }

    @Test("a good set followed by shallow ones reports only the shallow ones")
    func mixedSet() {
        var driver = Driver()
        let session = SyntheticSessions.mixedSet(validReps: 3, halfReps: 2)
        driver.feed(session.poseFrames())
        #expect(driver.reps == 3)
        #expect(driver.attempts.count == 2)
    }

    @Test("a tiny bob below the shallow minimum emits nothing", arguments: [143.0, 140.0, 138.0])
    func tinyBob(bottom: Double) {
        var driver = Driver()
        driver.feed(SyntheticPose.repSequence(reps: 3, secondsPerRep: 2.0, bottomDegrees: bottom))
        #expect(driver.reps == 0)
        #expect(driver.events.allSatisfy { $0 == .none })
    }

    @Test("a descent cut off by leaving the frame is dropped, not reported")
    func abortedDescent() {
        var driver = Driver()
        driver.feed(constant(elbowDegrees: 165, count: 10))
        driver.feed(constant(elbowDegrees: 130, count: 20))
        driver.feed((0..<20).map { _ in PoseFrame(timestamp: 3, joints: [:]) })
        #expect(driver.attempts.isEmpty)
        #expect(driver.tracker.peakDepthThisDescent == 0)
    }

    @Test("the peak is tracked while a descent is in progress")
    func peakWhileDescending() {
        var driver = Driver()
        driver.feed(constant(elbowDegrees: 165, count: 5))
        #expect(driver.tracker.peakDepthThisDescent == 0)
        driver.feed(constant(elbowDegrees: 130, count: 10))
        #expect(driver.tracker.peakDepthThisDescent > 0.5)
        #expect(driver.tracker.peakDepthThisDescent >= driver.tracker.depth)
    }

    @Test("reset clears depth and any descent in progress")
    func reset() {
        var driver = Driver()
        driver.feed(constant(elbowDegrees: 130, count: 10))
        #expect(driver.tracker.depth > 0.3)
        driver.tracker.reset()
        #expect(driver.tracker.depth == 0)
        #expect(driver.tracker.peakDepthThisDescent == 0)
        driver.feed(constant(elbowDegrees: 165, count: 10))
        #expect(driver.attempts.isEmpty)
    }

    @Test("the tracker never changes the count")
    func doesNotInfluenceCounting() {
        let frames = SyntheticPose.repSequence(reps: 5, secondsPerRep: 2.0)
        let plain = PushupPipeline(classifier: HeuristicPoseClassifier())
        var last: PipelineOutput?
        for frame in frames { last = plain.process(frame) }
        var driver = Driver()
        driver.feed(frames)
        #expect(driver.reps == last?.reps)
        #expect(driver.lastOutput?.rejectedReps == last?.rejectedReps)
    }

    @Test("identical input gives identical output")
    func deterministic() {
        let frames = SyntheticPose.repSequence(reps: 2, secondsPerRep: 2.0, bottomDegrees: 130)
        var a = Driver()
        var b = Driver()
        a.feed(frames)
        b.feed(frames)
        #expect(a.events == b.events)
        #expect(a.depths == b.depths)
    }
}
