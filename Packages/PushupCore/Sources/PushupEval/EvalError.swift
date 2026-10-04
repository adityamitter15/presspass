import Foundation

/// A runtime failure of the evaluation tool (exit code 1).
public enum EvalError: Error, Equatable, CustomStringConvertible {
    case notADirectory(String)
    case configUnreadable(String, String)
    case modelLoadFailed(String)
    case writeFailed(String, String)

    public var description: String {
        switch self {
        case .notADirectory(let path):
            return "data directory not found: \(path)"
        case .configUnreadable(let path, let reason):
            return "cannot read config file \(path): \(reason)"
        case .modelLoadFailed(let path):
            return "cannot load the Core ML model at \(path); it must be a compiled .mlmodelc directory"
        case .writeFailed(let path, let reason):
            return "cannot write \(path): \(reason)"
        }
    }
}
