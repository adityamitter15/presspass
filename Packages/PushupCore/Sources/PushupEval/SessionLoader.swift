import Foundation
import PushupCore

/// One recorded session together with the file it was read from.
public struct LoadedSession {
    public let file: String
    public let session: RecordedSession
}

/// A `*.json` file that was not usable, and why.
public struct SkippedFile: Codable, Equatable {
    public let file: String
    public let reason: String
}

public struct LoadResult {
    public let sessions: [LoadedSession]
    public let skipped: [SkippedFile]
}

public enum SessionLoader {
    /// Loads every `*.json` file directly inside `directory` (not
    /// recursive), sorted by file name. A file that cannot be read, decoded
    /// or has an unsupported schema goes into `skipped` instead of failing
    /// the whole load.
    public static func load(directory: URL) throws -> LoadResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EvalError.notADirectory(directory.path)
        }

        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let files = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var sessions: [LoadedSession] = []
        var skipped: [SkippedFile] = []
        for url in files {
            let name = url.lastPathComponent
            do {
                sessions.append(LoadedSession(file: name, session: try RecordedSession.load(from: url)))
            } catch {
                skipped.append(SkippedFile(file: name, reason: describe(error)))
            }
        }
        return LoadResult(sessions: sessions, skipped: skipped)
    }

    /// A one-line reason for a load failure.
    static func describe(_ error: Error) -> String {
        if let schemaError = error as? RecordedSessionError, case .unsupportedSchema(let found) = schemaError {
            return "unsupported schema \(found), expected \(RecordedSession.currentSchema)"
        }
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _):
                return "missing field '\(key.stringValue)'"
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                return "wrong type at \(path(context.codingPath))"
            case .dataCorrupted:
                return "not valid JSON"
            @unknown default:
                return "could not decode"
            }
        }
        return error.localizedDescription
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.isEmpty ? "top level" : codingPath.map(\.stringValue).joined(separator: ".")
    }
}
