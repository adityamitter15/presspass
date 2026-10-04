#if DEBUG
import Foundation
import PushupCore

/// Lightweight view of one saved recording for the list screen, so the list
/// never has to hold a whole session's frames.
struct RecordingSummary: Identifiable, Equatable {
    let url: URL
    let kind: RecordedSession.Kind
    let trueReps: Int?
    let liveReps: Int?
    let subject: String
    let tags: RecordedSession.Tags
    let createdAt: Date
    let frameCount: Int

    var id: URL { url }
}

/// File handling for the DEBUG recorder: saves sessions into
/// `Documents/Recordings/`, lists them, deletes them behind a guard and
/// zips the whole directory for export. Safe to call from any queue (the
/// summary cache is guarded by a lock).
final class RecordingStore: @unchecked Sendable {
    enum StoreError: Error, LocalizedError {
        case notAManagedRecording
        case nothingToExport
        case archiveFailed

        var errorDescription: String? {
            switch self {
            case .notAManagedRecording: return "That file is not a recording this app wrote."
            case .nothingToExport: return "There are no recordings to export."
            case .archiveFailed: return "Could not build the export archive."
            }
        }
    }

    private struct CacheEntry {
        let modified: Date
        let summary: RecordingSummary?
    }

    private let directoryOverride: URL?
    private let lock = NSLock()
    private var cache: [URL: CacheEntry] = [:]

    /// `directory` replaces `Documents/Recordings/`, for tests.
    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    /// `Documents/Recordings/`, created on demand.
    func recordingsDirectory() throws -> URL {
        let url: URL
        if let directoryOverride {
            url = directoryOverride
        } else {
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            url = documents.appendingPathComponent("Recordings", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `session` atomically under its generated file name.
    @discardableResult
    func save(_ session: RecordedSession) throws -> URL {
        let name = RecordedSession.fileName(kind: session.kind, createdAt: session.createdAt, id: session.id)
        let url = try recordingsDirectory().appendingPathComponent(name)
        try session.write(to: url)
        return url
    }

    /// Saved recordings, newest first. Each file is decoded at most once per
    /// modification date; unreadable files are skipped.
    func list() -> [RecordingSummary] {
        guard let directory = try? recordingsDirectory() else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var summaries: [RecordingSummary] = []
        var seen: Set<URL> = []
        for url in urls where RecordedSession.isRecordingFileName(url.lastPathComponent) {
            seen.insert(url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let summary = cachedSummary(for: url, modified: modified) {
                summaries.append(summary)
            }
        }

        lock.lock()
        cache = cache.filter { seen.contains($0.key) }
        lock.unlock()

        return summaries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes one recording. Only files directly inside the Recordings
    /// directory whose name `RecordedSession.isRecordingFileName` accepts
    /// can be deleted.
    func delete(_ url: URL) throws {
        let directory = try recordingsDirectory()
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent == directory.resolvingSymlinksInPath(),
              RecordedSession.isRecordingFileName(url.lastPathComponent) else {
            throw StoreError.notAManagedRecording
        }
        try FileManager.default.removeItem(at: url)
        lock.lock()
        cache[url] = nil
        lock.unlock()
    }

    /// Zips the Recordings directory into the temporary directory as
    /// `pushup-recordings-<yyyyMMdd-HHmmss>.zip` and returns its URL.
    func exportArchive() throws -> URL {
        let directory = try recordingsDirectory()
        let hasRecordings = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .contains(where: RecordedSession.isRecordingFileName)
        guard hasRecordings else { throw StoreError.nothingToExport }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushup-recordings-\(formatter.string(from: Date())).zip")

        var coordinationError: NSError?
        var copyError: Error?
        var copied = false
        // The coordinator deletes its zip when the accessor returns, so the
        // copy has to happen inside the block.
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipURL in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipURL, to: destination)
                copied = true
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard copied else { throw StoreError.archiveFailed }
        return destination
    }

    // MARK: - Cache

    private func cachedSummary(for url: URL, modified: Date) -> RecordingSummary? {
        lock.lock()
        let entry = cache[url]
        lock.unlock()
        if let entry, entry.modified == modified { return entry.summary }

        let summary = Self.decodeSummary(at: url, modified: modified)
        lock.lock()
        cache[url] = CacheEntry(modified: modified, summary: summary)
        lock.unlock()
        return summary
    }

    private static func decodeSummary(at url: URL, modified: Date) -> RecordingSummary? {
        guard let session = try? RecordedSession.load(from: url) else { return nil }
        return RecordingSummary(
            url: url,
            kind: session.kind,
            trueReps: session.trueReps,
            liveReps: session.live?.reps,
            subject: session.subject,
            tags: session.tags,
            createdAt: ISO8601DateFormatter().date(from: session.createdAt) ?? modified,
            frameCount: session.frames.count
        )
    }
}
#endif
