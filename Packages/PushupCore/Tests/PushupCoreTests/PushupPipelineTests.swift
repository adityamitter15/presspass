import Foundation
import Testing
import PushupCore

/// Counts how often it is asked to classify, delegating to the heuristic.
private final class SpyClassifier: PoseClassifier {
    private let inner = HeuristicPoseClassifier()
    private(set) var calls = 0

    func classify(_ features: [Float]) -> (label: PoseLabel, confidence: Float) {
        calls += 1
        return inner.classify(features)
    }
}

private func makePipeline() -> PushupPipeline {
    PushupPipeline(classifier: HeuristicPoseClassifier())
}

@discardableResult
private func run(_ frames: [PoseFrame], through pipeline: PushupPipeline) -> PipelineOutput? {
    var last: PipelineOutput?
    for frame in frames { last = pipeline.process(frame) }
    return last
}

@Suite("PushupPipeline")
struct PushupPipelineTests {
    @Test("clean reps at 2 s per rep are all counted", arguments: [1, 5, 10])
    func cleanRepsCounted(_ reps: Int) throws {
        let pipeline = makePipeline()
        let output = try #require(run(SyntheticPose.repSequence(reps: reps, secondsPerRep: 2.0), through: pipeline))
        #expect(output.reps == reps)
        #expect(output.rejectedReps == 0)
        #expect(output.phase == .up)
        #expect(output.ignoreReason == .none)
    }

    @Test("shallow half reps that only reach about 130 degrees count nothing")
    func shallowRepsCountNothing() throws {
        let frames = SyntheticPose.repSequence(reps: 6, secondsPerRep: 2.0, bottomDegrees: 130)
        let output = try #require(run(frames, through: makePipeline()))
        #expect(output.reps == 0)
        #expect(output.rejectedReps == 0)
    }

    @Test("reps that only just reach the down threshold count, ones that stop short do not")
    func depthBoundary() throws {
        let deep = try #require(run(SyntheticPose.repSequence(reps: 3, secondsPerRep: 2.0, bottomDegrees: 100), through: makePipeline()))
        #expect(deep.reps == 3)
        let shallow = try #require(run(SyntheticPose.repSequence(reps: 3, secondsPerRep: 2.0, bottomDegrees: 125), through: makePipeline()))
        #expect(shallow.reps == 0)
    }

    @Test("an arm wave with the wrists above the shoulders counts nothing and reports the posture failure")
    func armWaveCountsNothing() throws {
        var options = SyntheticPose.Options()
        options.wristsAboveShoulders = true
        let frames = SyntheticPose.repSequence(reps: 5, secondsPerRep: 2.0, options)
        let pipeline = makePipeline()
        var outputs: [PipelineOutput] = []
        for frame in frames { outputs.append(pipeline.process(frame)) }

        let last = try #require(outputs.last)
        #expect(last.reps == 0)
        #expect(last.rejectedReps == 0)
        #expect(last.phase == .idle)
        #expect(last.ignoreReason == .notInPushupPosture)
        #expect(outputs.allSatisfy { !$0.postureValid })
        #expect(outputs.allSatisfy { $0.requiredJointsConfident })
        #expect(outputs.allSatisfy { $0.features != nil })
    }

    @Test("low-confidence wrists report lowConfidence and count nothing")
    func lowConfidenceWristsIgnored() throws {
        var options = SyntheticPose.Options()
        options.confidenceOverrides = [.leftWrist: 0.2, .rightWrist: 0.2]
        let output = try #require(run(SyntheticPose.repSequence(reps: 3, secondsPerRep: 2.0, options), through: makePipeline()))
        #expect(output.reps == 0)
        #expect(output.ignoreReason == .lowConfidence)
        #expect(!output.requiredJointsConfident)
        #expect(output.postureValid)
    }

    @Test("frames with no joints leave the count unchanged and return nil features")
    func emptyFramesLeaveCountUnchanged() throws {
        let pipeline = makePipeline()
        let counted = try #require(run(SyntheticPose.repSequence(reps: 3, secondsPerRep: 2.0), through: pipeline))
        #expect(counted.reps == 3)

        let empty = pipeline.process(PoseFrame(timestamp: 100, joints: [:]))
        #expect(empty.features == nil)
        #expect(empty.frameLabel == nil)
        #expect(empty.frameConfidence == nil)
        #expect(empty.reps == 3)
        #expect(empty.rejectedReps == counted.rejectedReps)
        #expect(empty.phase == counted.phase)
        #expect(empty.currentLabel == counted.currentLabel)
        #expect(empty.ignoreReason == counted.ignoreReason)
        #expect(!empty.postureValid)
        #expect(!empty.requiredJointsConfident)
    }

    @Test("a frame that fails the feature gate never reaches the classifier or the counter")
    func gatedFrameSkipsClassifier() {
        let spy = SpyClassifier()
        let pipeline = PushupPipeline(classifier: spy)

        let gated = pipeline.process(PoseFrame(timestamp: 0, joints: [:]))
        #expect(gated.features == nil)
        #expect(spy.calls == 0)
        #expect(gated.phase == .idle)

        // Low-confidence pose: fails the feature gate, so no classification
        // and no ignore reason is recorded either (the counter never saw it).
        var options = SyntheticPose.Options()
        options.confidence = 0.1
        let lowConf = pipeline.process(SyntheticPose.frame(timestamp: 0.1, elbowDegrees: 150, options))
        #expect(lowConf.features == nil)
        #expect(lowConf.ignoreReason == .none)
        #expect(spy.calls == 0)

        let good = pipeline.process(SyntheticPose.frame(timestamp: 0.2, elbowDegrees: 150))
        #expect(good.features != nil)
        #expect(spy.calls == 1)
    }

    @Test("an output for a good frame carries the intermediates")
    func outputCarriesIntermediates() throws {
        let output = makePipeline().process(SyntheticPose.frame(timestamp: 0, elbowDegrees: 170))
        let features = try #require(output.features)
        #expect(features.count == PushupFeatureExtractor.featureDim)
        #expect(output.frameLabel == .up)
        #expect(output.frameConfidence == 0.9)
        #expect(output.postureValid)
        #expect(output.requiredJointsConfident)
        // The counter has seen one frame: label is recorded, phase not yet entered.
        #expect(output.currentLabel == .up)
        #expect(output.phase == .idle)
    }

    @Test("reset clears the count and the classifier-independent state")
    func resetClearsCount() throws {
        let pipeline = makePipeline()
        let first = try #require(run(SyntheticPose.repSequence(reps: 4, secondsPerRep: 2.0), through: pipeline))
        #expect(first.reps == 4)

        pipeline.reset()
        let afterReset = pipeline.process(PoseFrame(timestamp: 0, joints: [:]))
        #expect(afterReset.reps == 0)
        #expect(afterReset.phase == .idle)
        #expect(afterReset.currentLabel == .notPushup)

        // Timestamps restart at zero for the next set; the count must follow.
        let second = try #require(run(SyntheticPose.repSequence(reps: 2, secondsPerRep: 2.0), through: pipeline))
        #expect(second.reps == 2)
    }

    @Test("the pipeline matches a hand-wired extract, classify, gate, count loop frame by frame")
    func matchesManualComposition() {
        let frames = SyntheticPose.repSequence(reps: 4, secondsPerRep: 1.8)
            + SyntheticPose.repSequence(reps: 2, secondsPerRep: 2.2, bottomDegrees: 125, startTime: 20)

        let pipeline = makePipeline()
        let classifier = HeuristicPoseClassifier()
        let counter = RepCounter()

        for (index, frame) in frames.enumerated() {
            let output = pipeline.process(frame)
            if let features = PushupFeatureExtractor.extract(frame.joints) {
                let (label, confidence) = classifier.classify(features)
                counter.process(RepCounterFrameInput(
                    timestamp: frame.timestamp,
                    label: label,
                    labelConfidence: confidence,
                    postureValid: PostureGate.isPushupPosture(frame.joints),
                    requiredJointsConfident: PostureGate.requiredJointsConfident(frame.joints)
                ))
            }
            #expect(output.reps == counter.reps, "frame \(index)")
            #expect(output.rejectedReps == counter.rejectedReps, "frame \(index)")
            #expect(output.phase == counter.phase, "frame \(index)")
            #expect(output.currentLabel == counter.currentLabel, "frame \(index)")
            #expect(output.ignoreReason == counter.lastIgnoreReason, "frame \(index)")
        }
    }

    @Test("reps at 0.6 s each are not all counted")
    func veryFastRepsAreNotAllCounted() throws {
        let performed = 10
        let pipeline = makePipeline()
        let output = try #require(run(SyntheticPose.repSequence(reps: performed, secondsPerRep: 0.6), through: pipeline))
        #expect(output.reps < performed)
        // Observed: 4 of 10 counted, rejectedReps == 0. The shortfall is the
        // minimum dwell rule (minPhaseDuration, 0.5 s): at 0.6 s per rep the
        // down and up stretches are each only about 0.2 to 0.3 s, so many
        // phase changes are held back until the dwell has elapsed and the
        // movement has already moved on. The 1 s spacing rule is not involved
        // (nothing is rejected), because it is implied by the dwell rule.
        #expect(output.rejectedReps == 0)
    }

    @Test("a continuous two-minute set stays accurate")
    func longSet() throws {
        let output = try #require(run(SyntheticPose.repSequence(reps: 60, secondsPerRep: 2.0), through: makePipeline()))
        #expect(output.reps == 60)
    }
}
