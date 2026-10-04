import Foundation

/// Every tunable threshold the pipeline reads, in one value that can be
/// written to and read from a JSON file. Used by the offline evaluation tool
/// to replay recordings under a different configuration; the app itself runs
/// the defaults. A missing key decodes to its default, at this level and
/// inside each nested config.
public struct PipelineConfig: Codable, Equatable {
    public var repCounter: RepCounter.Config
    public var heuristic: HeuristicPoseClassifier.Config

    public static let `default` = PipelineConfig()

    public init(
        repCounter: RepCounter.Config = .default,
        heuristic: HeuristicPoseClassifier.Config = .default
    ) {
        self.repCounter = repCounter
        self.heuristic = heuristic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            repCounter: try container.decodeIfPresent(RepCounter.Config.self, forKey: .repCounter) ?? .default,
            heuristic: try container.decodeIfPresent(HeuristicPoseClassifier.Config.self, forKey: .heuristic) ?? .default
        )
    }

    /// A fresh pipeline (the rep counter and the heuristic both keep state
    /// between frames, so build one per recording). Uses a
    /// `HeuristicPoseClassifier` built from `heuristic` when no classifier is
    /// passed.
    public func makePipeline(classifier: PoseClassifier? = nil) -> PushupPipeline {
        PushupPipeline(
            classifier: classifier ?? HeuristicPoseClassifier(config: heuristic),
            repCounter: RepCounter(config: repCounter)
        )
    }
}
