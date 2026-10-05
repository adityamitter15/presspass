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
    let notes: String
    let poseLabel: PoseLabel?
    let createdAt: Date
    let frameCount: Int
    /// True when the session names a video and that file is next to it.
    let hasVideo: Bool
    /// Whether the app's count was on screen while this take was recorded.
    /// nil for files from before that was recorded.
    let countVisible: Bool?
    /// ISO 8601 time of the last manual edit of the labels, nil if never edited.
    let editedAt: String?

    var id: URL { url }

    init(
        url: URL,
        kind: RecordedSession.Kind,
        trueReps: Int?,
        liveReps: Int?,
        subject: String,
        tags: RecordedSession.Tags,
        notes: String = "",
        poseLabel: PoseLabel? = nil,
        createdAt: Date,
        frameCount: Int,
        hasVideo: Bool,
        countVisible: Bool? = nil,
        editedAt: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.trueReps = trueReps
        self.liveReps = liveReps
        self.subject = subject
        self.tags = tags
        self.notes = notes
        self.poseLabel = poseLabel
        self.createdAt = createdAt
        self.frameCount = frameCount
        self.hasVideo = hasVideo
        self.countVisible = countVisible
        self.editedAt = editedAt
    }

    init(session: RecordedSession, url: URL, modified: Date, hasVideo: Bool) {
        self.init(
            url: url,
            kind: session.kind,
            trueReps: session.trueReps,
            liveReps: session.live?.reps,
            subject: session.subject,
            tags: session.tags,
            notes: session.notes,
            poseLabel: session.poseLabel,
            createdAt: ISO8601DateFormatter().date(from: session.createdAt) ?? modified,
            frameCount: session.frames.count,
            hasVideo: hasVideo,
            countVisible: session.countVisible,
            editedAt: session.editedAt
        )
    }
}

/// File handling for the DEBUG recorder: saves sessions (and their optional
/// video) into `Documents/Recordings/`, lists them, rewrites their labels,
/// deletes them behind a guard and zips the whole directory for export. Safe
/// to call from any queue (the summary cache is guarded by a lock).
///
/// With `demoSummaries` the store is in-memory only: it lists, edits and
/// deletes those samples and writes no files, for screenshots.
final class RecordingStore: @unchecked Sendable {
    enum StoreError: Error, LocalizedError {
        case notAManagedRecording
        case nothingToExport
        case archiveFailed
        case videoWithoutInfo
        case invalidLabels(String)

        var errorDescription: String? {
            switch self {
            case .invalidLabels(let reason): return reason
            case .videoWithoutInfo: return "A video file was given without the session's video details."
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
    /// Non-nil in demo mode: the whole store lives in this array.
    private var demoSummaries: [RecordingSummary]?

    /// `directory` replaces `Documents/Recordings/`, for tests.
    init(directory: URL? = nil, demoSummaries: [RecordingSummary]? = nil) {
        directoryOverride = directory
        self.demoSummaries = demoSummaries
        isDemo = demoSummaries != nil
    }

    let isDemo: Bool

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

    /// Writes `session` atomically under its generated file name. When
    /// `temporaryVideo` is given, that file is moved into the directory under
    /// the matching `.mp4` name, and `session.video` must describe it (its
    /// `file` is set to the final name). The video goes in first and the
    /// session file second, so a session never names a video that is not
    /// there; if the session write fails, the video is moved back to where it
    /// came from (or deleted if that fails too) and nothing is left in the
    /// directory.
    @discardableResult
    func save(_ session: RecordedSession, temporaryVideo: URL? = nil) throws -> URL {
        if isDemo {
            let name = RecordedSession.fileName(kind: session.kind, createdAt: session.createdAt, id: session.id)
            let url = URL(fileURLWithPath: "/demo").appendingPathComponent(name)
            let summary = RecordingSummary(session: session, url: url, modified: Date(), hasVideo: false)
            lock.lock()
            demoSummaries?.append(summary)
            lock.unlock()
            if let temporaryVideo { try? FileManager.default.removeItem(at: temporaryVideo) }
            return url
        }
        let directory = try recordingsDirectory()
        let name = RecordedSession.fileName(kind: session.kind, createdAt: session.createdAt, id: session.id)
        let url = directory.appendingPathComponent(name)

        guard let temporaryVideo else {
            try session.write(to: url)
            return url
        }

        var session = session
        guard session.video != nil else { throw StoreError.videoWithoutInfo }
        let videoName = RecordedSession.videoFileName(forSessionFileName: name)
        session.video?.file = videoName
        let videoURL = directory.appendingPathComponent(videoName)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: videoURL.path) {
            try fileManager.removeItem(at: videoURL)
        }
        try fileManager.moveItem(at: temporaryVideo, to: videoURL)
        do {
            try session.write(to: url)
        } catch {
            do {
                try fileManager.moveItem(at: videoURL, to: temporaryVideo)
            } catch {
                try? fileManager.removeItem(at: videoURL)
            }
            throw error
        }
        return url
    }

    /// Saved recordings, newest first. Each file is decoded at most once per
    /// modification date; unreadable files are skipped.
    func list() -> [RecordingSummary] {
        lock.lock()
        let demo = demoSummaries
        lock.unlock()
        if let demo { return demo.sorted { $0.createdAt > $1.createdAt } }
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

    /// Removes one recording and its video, if it has one. Only files directly
    /// inside the Recordings directory whose name
    /// `RecordedSession.isRecordingFileName` accepts can be deleted.
    func delete(_ url: URL) throws {
        if isDemo {
            lock.lock()
            demoSummaries?.removeAll { $0.url == url }
            lock.unlock()
            return
        }
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

        let videoURL = directory.appendingPathComponent(
            RecordedSession.videoFileName(forSessionFileName: url.lastPathComponent)
        )
        if FileManager.default.fileExists(atPath: videoURL.path) {
            try FileManager.default.removeItem(at: videoURL)
        }
    }

    // MARK: - Editing labels

    /// Rewrites the labels of one saved take. Loads the session, applies
    /// `edit`, then puts back every field the edit must not touch (the frames,
    /// motion, video, live result, device, id, creation time, kind and the
    /// count-visible record) so a bug in `edit` cannot damage the recording,
    /// checks the labels, stamps `editedAt` and writes the file atomically
    /// under the same name. The video file is not touched. Throws
    /// `invalidLabels` without writing anything when the result is not a
    /// valid take.
    func updateLabels(of url: URL, _ edit: (inout RecordedSession) -> Void) throws {
        if isDemo {
            lock.lock()
            defer { lock.unlock() }
            guard let index = demoSummaries?.firstIndex(where: { $0.url == url }),
                  let current = demoSummaries?[index] else {
                throw StoreError.notAManagedRecording
            }
            let edited = try Self.editedSession(from: Self.stubSession(for: current), edit)
            demoSummaries?[index] = RecordingSummary(
                session: edited, url: url, modified: current.createdAt, hasVideo: current.hasVideo
            )
            return
        }

        let directory = try recordingsDirectory()
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent == directory.resolvingSymlinksInPath(),
              RecordedSession.isRecordingFileName(url.lastPathComponent) else {
            throw StoreError.notAManagedRecording
        }
        let original = try RecordedSession.load(from: url)
        let edited = try Self.editedSession(from: original, edit)
        try edited.write(to: url)
        lock.lock()
        cache[url] = nil
        lock.unlock()
    }

    /// The pure part of `updateLabels`: the edited, checked copy of `original`.
    static func editedSession(
        from original: RecordedSession,
        now: Date = Date(),
        _ edit: (inout RecordedSession) -> Void
    ) throws -> RecordedSession {
        var session = original
        edit(&session)

        // Not label fields: always the original's.
        session.schema = original.schema
        session.id = original.id
        session.createdAt = original.createdAt
        session.kind = original.kind
        session.device = original.device
        session.live = original.live
        session.frames = original.frames
        session.motion = original.motion
        session.video = original.video
        session.countVisible = original.countVisible

        session.subject = session.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        session.notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.subject.isEmpty else {
            throw StoreError.invalidLabels("The subject cannot be empty.")
        }

        switch session.kind {
        case .set:
            guard let reps = session.trueReps, (0...300).contains(reps) else {
                throw StoreError.invalidLabels("The true count must be a whole number from 0 to 300.")
            }
            session.poseLabel = original.poseLabel
        case .negative:
            session.trueReps = 0
            session.poseLabel = original.poseLabel
        case .pose:
            session.trueReps = nil
            session.poseLabel = session.poseLabel ?? original.poseLabel
        case .workout:
            session.trueReps = nil
            session.poseLabel = nil
        }
        if session.kind != .set {
            session.tags.tempo = .na
            session.tags.variant = .na
            session.tags.cheat = .none
            session.tags.hands = nil
            session.tags.support = nil
            session.tags.width = nil
        } else if session.tags.hands != nil || session.tags.support != nil || session.tags.width != nil {
            // The three technique fields are the record, `variant` only a
            // summary of them: fill in any missing one and derive `variant`
            // again, so the two cannot disagree whatever `edit` did.
            session.tags.setTechnique()
        }
        session.editedAt = RecordedSession.iso8601String(from: now)
        return session
    }

    /// A frameless session standing in for a demo summary, so demo edits go
    /// through the same checks as real ones.
    private static func stubSession(for summary: RecordingSummary) -> RecordedSession {
        RecordedSession(
            id: UUID().uuidString,
            createdAt: RecordedSession.iso8601String(from: summary.createdAt),
            kind: summary.kind,
            trueReps: summary.trueReps,
            poseLabel: summary.poseLabel,
            subject: summary.subject,
            tags: summary.tags,
            notes: summary.notes,
            device: DeviceInfo(
                model: "demo", systemVersion: "", appVersion: "", appBuild: "",
                poseModel: "", cameraPosition: "front", featureVersion: ""
            ),
            live: summary.liveReps.map { LiveResult(reps: $0, rejectedReps: 0, classifier: "heuristic") },
            frames: [],
            countVisible: summary.countVisible,
            editedAt: summary.editedAt
        )
    }

    /// Zips the Recordings directory into the temporary directory as
    /// `pushup-recordings-<yyyyMMdd-HHmmss>.zip` and returns its URL.
    func exportArchive() throws -> URL {
        if isDemo { throw StoreError.nothingToExport }
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
        let hasVideo = session.video.map {
            $0.file == RecordedSession.videoFileName(forSessionFileName: url.lastPathComponent)
                && FileManager.default.fileExists(
                    atPath: url.deletingLastPathComponent().appendingPathComponent($0.file).path
                )
        } ?? false
        return RecordingSummary(session: session, url: url, modified: modified, hasVideo: hasVideo)
    }
}
#endif
