import Foundation
import PushupCore

/// Per-frame features for every session, as one CSV. This is the single
/// source of features for model training, so no other language needs its own
/// copy of the landmark mapping or the feature code.
public enum FeaturesCSV {
    public static var header: String {
        let features = (0..<PushupFeatureExtractor.featureDim).map { "f\($0)" }
        let columns = ["session_id", "frame", "t", "has_features"]
            + features
            + ["posture_valid", "joints_confident", "heuristic_label", "heuristic_confidence"]
        return columns.joined(separator: ",")
    }

    /// Header plus one row per frame, newline terminated. Each session runs
    /// through a fresh pipeline built from `config`, so the heuristic label
    /// columns are exactly what the app would have shown.
    public static func render(sessions: [LoadedSession], config: PipelineConfig) -> String {
        var lines = [header]
        for entry in sessions {
            let pipeline = config.makePipeline()
            for (index, frame) in entry.session.poseFrames().enumerated() {
                let output = pipeline.process(frame)
                lines.append(row(sessionID: entry.session.id, frame: index, time: frame.timestamp, output: output))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func row(sessionID: String, frame: Int, time: TimeInterval, output: PipelineOutput) -> String {
        var cells: [String] = [escape(sessionID), String(frame), String(time), output.features == nil ? "0" : "1"]
        if let features = output.features {
            cells.append(contentsOf: features.map { String($0) })
        } else {
            cells.append(contentsOf: Array(repeating: "", count: PushupFeatureExtractor.featureDim))
        }
        cells.append(output.postureValid ? "1" : "0")
        cells.append(output.requiredJointsConfident ? "1" : "0")
        cells.append(output.frameLabel?.rawValue ?? "")
        cells.append(output.frameConfidence.map { String($0) } ?? "")
        return cells.joined(separator: ",")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
