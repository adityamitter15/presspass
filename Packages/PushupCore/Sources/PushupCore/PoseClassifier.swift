import CoreML
import Foundation

/// Coarse pose classification for one frame's feature vector.
public enum PoseLabel: String {
    case up
    case down
    case notPushup = "not_pushup"
}

/// Anything that can turn a 25-dim feature vector into a pose label +
/// confidence. Lets the workout module swap between the shipped heuristic
/// and a trained Core ML model without either the UI or `RepCounter`
/// caring which one is active.
public protocol PoseClassifier {
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
/// `PostureGate`, not here.
public final class HeuristicPoseClassifier: PoseClassifier {
    /// Tunable thresholds. The defaults are the shipped behaviour.
    public struct Config: Equatable {
        public var downElbowDegrees: Float
        public var upElbowDegrees: Float
        public var confidentScore: Float
        public var ambiguousScore: Float

        public static let `default` = Config()

        public init(
            downElbowDegrees: Float = 120,
            upElbowDegrees: Float = 145,
            confidentScore: Float = 0.9,
            ambiguousScore: Float = 0.35
        ) {
            self.downElbowDegrees = downElbowDegrees
            self.upElbowDegrees = upElbowDegrees
            self.confidentScore = confidentScore
            self.ambiguousScore = ambiguousScore
        }
    }

    private let config: Config
    private var previousLabel: PoseLabel = .notPushup

    public init(config: Config = .default) {
        self.config = config
    }

    public func classify(_ features: [Float]) -> (label: PoseLabel, confidence: Float) {
        guard features.count == PushupFeatureExtractor.featureDim else {
            return (.notPushup, 0)
        }

        let leftElbowDeg = radiansToDegrees(features[PushupFeatureExtractor.leftElbowAngleIndex])
        let rightElbowDeg = radiansToDegrees(features[PushupFeatureExtractor.rightElbowAngleIndex])
        let meanElbowDeg = (leftElbowDeg + rightElbowDeg) / 2

        if meanElbowDeg < config.downElbowDegrees {
            previousLabel = .down
            return (.down, config.confidentScore)
        }

        if meanElbowDeg > config.upElbowDegrees {
            previousLabel = .up
            return (.up, config.confidentScore)
        }

        // Ambiguous middle band: keep whatever the last confident label
        // was, but at low confidence so RepCounter's hysteresis doesn't
        // treat it as a fresh confident observation.
        return (previousLabel, config.ambiguousScore)
    }
}

/// Loads a trained `PushupPoseClassifier.mlmodel` (compiled to
/// `.mlmodelc` by Xcode) from the app bundle if one has been shipped.
/// Deliberately built against the generic `MLModel` / feature-provider
/// API rather than an auto-generated model class, since the model file
/// does not exist yet: a generated Swift wrapper for it would be a
/// build-time dependency this target can't have until training produces
/// a model and it's dropped into the bundle.
public final class CoreMLPoseClassifier: PoseClassifier {
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
    public static func loadFromBundle(_ bundle: Bundle = .main) -> CoreMLPoseClassifier? {
        guard let url = bundle.url(forResource: modelResourceName, withExtension: "mlmodelc") else {
            return nil
        }
        return load(compiledModelURL: url)
    }

    /// Returns a classifier backed by the compiled model (`.mlmodelc`) at
    /// `compiledModelURL`, or nil if it fails to load.
    public static func load(compiledModelURL: URL) -> CoreMLPoseClassifier? {
        guard let model = try? MLModel(contentsOf: compiledModelURL) else {
            return nil
        }
        return CoreMLPoseClassifier(model: model)
    }

    public func classify(_ features: [Float]) -> (label: PoseLabel, confidence: Float) {
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
public enum PoseClassifierFactory {
    public static func makeDefault() -> PoseClassifier {
        if let coreML = CoreMLPoseClassifier.loadFromBundle() {
            return coreML
        }
        return HeuristicPoseClassifier()
    }
}

private func radiansToDegrees(_ radians: Float) -> Float {
    radians * 180 / .pi
}
