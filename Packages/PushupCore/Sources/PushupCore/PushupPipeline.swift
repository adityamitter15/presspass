import Foundation

/// Everything the pipeline knows after one frame: the rep counter's state
/// plus the per-frame intermediates (features, classifier output, gates) so
/// callers like the debug HUD and an offline evaluator don't have to
/// recompute them.
public struct PipelineOutput {
    public let reps: Int
    public let rejectedReps: Int
    public let phase: RepPhase
    /// `RepCounter.currentLabel`.
    public let currentLabel: PoseLabel
    public let ignoreReason: RepCounterIgnoreReason
    /// Nil when the frame failed the feature extractor's confidence gate.
    public let features: [Float]?
    /// Classifier output for this frame; nil when `features` is nil.
    public let frameLabel: PoseLabel?
    public let frameConfidence: Float?
    public let postureValid: Bool
    public let requiredJointsConfident: Bool
}

/// The single entry point from a `PoseFrame` to counting state: feature
/// extraction, classification, anti-cheat gates, rep counting. Used by the
/// workout view model on-device and by offline replay tooling, so both run
/// exactly the same code.
public final class PushupPipeline {
    private let classifier: PoseClassifier
    private let repCounter: RepCounter

    public init(classifier: PoseClassifier, repCounter: RepCounter = RepCounter()) {
        self.classifier = classifier
        self.repCounter = repCounter
    }

    public func reset() {
        repCounter.reset()
    }

    /// Feeds one frame through the pipeline. A frame that fails the feature
    /// confidence gate never reaches the classifier or the rep counter; the
    /// returned output then carries the counter's unchanged state with
    /// `features == nil`.
    @discardableResult
    public func process(_ frame: PoseFrame) -> PipelineOutput {
        let postureValid = PostureGate.isPushupPosture(frame.joints)
        let requiredJointsConfident = PostureGate.requiredJointsConfident(frame.joints)

        guard let features = PushupFeatureExtractor.extract(frame.joints) else {
            return output(
                features: nil,
                frameLabel: nil,
                frameConfidence: nil,
                postureValid: postureValid,
                requiredJointsConfident: requiredJointsConfident
            )
        }

        let (label, confidence) = classifier.classify(features)

        let input = RepCounterFrameInput(
            timestamp: frame.timestamp,
            label: label,
            labelConfidence: confidence,
            postureValid: postureValid,
            requiredJointsConfident: requiredJointsConfident
        )
        repCounter.process(input)

        return output(
            features: features,
            frameLabel: label,
            frameConfidence: confidence,
            postureValid: postureValid,
            requiredJointsConfident: requiredJointsConfident
        )
    }

    private func output(
        features: [Float]?,
        frameLabel: PoseLabel?,
        frameConfidence: Float?,
        postureValid: Bool,
        requiredJointsConfident: Bool
    ) -> PipelineOutput {
        PipelineOutput(
            reps: repCounter.reps,
            rejectedReps: repCounter.rejectedReps,
            phase: repCounter.phase,
            currentLabel: repCounter.currentLabel,
            ignoreReason: repCounter.lastIgnoreReason,
            features: features,
            frameLabel: frameLabel,
            frameConfidence: frameConfidence,
            postureValid: postureValid,
            requiredJointsConfident: requiredJointsConfident
        )
    }
}
