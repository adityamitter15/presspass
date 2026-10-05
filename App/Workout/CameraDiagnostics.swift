#if DEBUG
import Foundation

/// DEBUG aid: appends timestamped lines about the camera pipeline to
/// `Documents/Diagnostics/camera.log`, so a fault seen on a phone can be read
/// back from a Mac instead of guessed at. Compiled out of Release builds.
enum CameraDiagnostics {
    private static let queue = DispatchQueue(label: "com.addymitter.pushuptime.diagnostics")

    private static let fileURL: URL? = {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("camera.log")
    }()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String) {
        let now = Date()
        queue.async {
            guard let fileURL, let data = "\(formatter.string(from: now)) \(message)\n".data(using: .utf8) else {
                return
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
#endif
