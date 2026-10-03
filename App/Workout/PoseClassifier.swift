import CoreML
import Foundation

/// Coarse pose classification for one frame's feature vector.
enum PoseLabel: String {
    case up
    case down
    case notPushup = "not_pushup"
}

/// Anything that can turn a 25-dim feature vector into a pose label +
/// confidence. Lets the workout module swap between the shipped heuristic
/// and a trained Core ML model without either the UI or `RepCounter`
/// caring which one is active.
protocol PoseClassifier {
    func classify(_ features: [Float]) -> (label: PoseLabel, confidence: Float)
}

/// Default classifier, ships day one with no trained model required.
/// Tuned for a FRONT view: phone on the floor facing the user head-on.
/// From that perspective the torso appears near-vertical and heavily
/// foreshortened, so only the projected elbow angles are used, with wider
/// thresholds than a side view would need (the projection compresses the
/// bend). A low-confidence "continuation" of the previous label in the
/// ambiguous middle band avoids flicker before `RepCounter`'s hysteresis
/// even gets involved. Posture gating (wrists below shoulders) lives in
/// `WorkoutViewModel`, not here.
final class HeuristicPoseClassifier: PoseClassifier {
    /// Feature vector indices, matching PushupFeatureExtractor's layout.
    private enum FeatureIndex {
        static let leftElbowAngle = 20
        static let rightElbowAngle = 21
    }

    private static let downElbowDegreesThreshold: Float = 120
    private static let upElbowDegreesThreshold: Float = 145

    private var previousLabel: PoseLabel = .notPushup

    func classify(_ features: [Float]) -> (label: PoseLabel, confidence: Float) {
        guard features.count == PushupFeatureExtractor.featureDim else {
            return (.notPushup, 0)
        }

        let leftElbowDeg = radiansToDegrees(features[FeatureIndex.leftElbowAngle])
        let rightElbowDeg = radiansToDegrees(features[FeatureIndex.rightElbowAngle])
        let meanElbowDeg = (leftElbowDeg + rightElbowDeg) / 2

        if meanElbowDeg < Self.downElbowDegreesThreshold {
            previousLabel = .down
            return (.down, 0.9)
        }

        if meanElbowDeg > Self.upElbowDegreesThreshold {
            previousLabel = .up
            return (.up, 0.9)
        }

        // Ambiguous middle band: keep whatever the last confident label
        // was, but at low confidence so RepCounter's hysteresis doesn't
        // treat it as a fresh confident observation.
        return (previousLabel, 0.35)
    }
}

/// Loads a trained `PushupPoseClassifier.mlmodel` (compiled to
/// `.mlmodelc` by Xcode) from the app bundle if one has been shipped.
/// Deliberately built against the generic `MLModel` / feature-provider
/// API rather than an auto-generated model class, since the model file
/// does not exist yet — a generated Swift wrapper for it would be a
/// build-time dependency this target can't have until training produces
/// a model and it's dropped into the bundle.
final class CoreMLPoseClassifier: PoseClassifier {
    private static let modelResourceName = "PushupPoseClassifier"
    private static let inputFeatureName = "pose_features"
    // Output feature names must match LABEL_OUTPUT_NAME /
    // PROBABILITY_OUTPUT_NAME in training/coreml_export.py.
    private static let classLabelFeatureName = "label"
    private static let probabilitiesFeatureName = "labelProbability"

    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    /// Returns a classifier backed by the bundled model, or nil if no
    /// model is present or it fails to load. Callers should fall back to
    /// `HeuristicPoseClassifier` when this returns nil.
    static func loadFromBundle() -> CoreMLPoseClassifier? {
        guard let url = Bundle.main.url(forResource: modelResourceName, withExtension: "mlmodelc") else {
            return nil
        }
        guard let model = try? MLModel(contentsOf: url) else {
            return nil
        }
        return CoreMLPoseClassifier(model: model)
    }

    func classify(_ features: [Float]) -> (label: PoseLabel, confidence: Float) {
        guard features.count == PushupFeatureExtractor.featureDim,
              let inputArray = try? MLMultiArray(shape: [NSNumber(value: features.count)], dataType: .float32) else {
            return (.notPushup, 0)
        }
        for (index, value) in features.enumerated() {
            inputArray[index] = NSNumber(value: value)
        }

        guard let provider = try? MLDictionaryFeatureProvider(
            dictionary: [Self.inputFeatureName: MLFeatureValue(multiArray: inputArray)]
        ), let result = try? model.prediction(from: provider) else {
            return (.notPushup, 0)
        }

        guard let labelString = result.featureValue(for: Self.classLabelFeatureName)?.stringValue,
              let label = PoseLabel(rawValue: labelString) else {
            return (.notPushup, 0)
        }

        var confidence: Float = 1.0
        if let probabilities = result.featureValue(for: Self.probabilitiesFeatureName)?.dictionaryValue {
            if let probability = probabilities[labelString] {
                confidence = Float(truncating: probability)
            }
        }
        return (label, confidence)
    }
}

/// Picks the best available classifier: the Core ML model if one has
/// been shipped in the bundle, otherwise the heuristic. Call once per
/// workout session (the heuristic keeps a little state between frames).
enum PoseClassifierFactory {
    static func makeDefault() -> PoseClassifier {
        if let coreML = CoreMLPoseClassifier.loadFromBundle() {
            return coreML
        }
        return HeuristicPoseClassifier()
    }
}

private func radiansToDegrees(_ radians: Float) -> Float {
    radians * 180 / .pi
}
