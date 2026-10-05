#if DEBUG
import Foundation
import PushupCore

/// DEBUG builds only. Buffers the raw pose frames of an ordinary workout and,
/// when it ends, writes them as a `RecordedSession` of kind `workout` into
/// `Documents/WorkoutLogs/`, so a fault seen on a phone can be replayed
/// through `WorkoutSessionEngine` and turned into a test. Never writes video.
///
/// The log has no human count (`trueReps` nil); `live` holds what the engine
/// counted, `subject` is "app", the tags are the defaults and `notes` lists
/// the values of the session config that differ from the default. Only the
/// newest `maxLogs` logs are kept and a log stops at `maxSeconds` of frames.
/// Use from the main queue.
final class WorkoutFlightRecorder {
    static let maxLogs = 20
    static let maxSeconds: TimeInterval = 300
    static let subject = "app"

    private let directory: URL?
    private var frames: [RecordedFrame] = []
    private var originTimestamp: TimeInterval?
    private var originPresentation: TimeInterval?
    private var startedAt = Date()
    private let writeQueue = DispatchQueue(label: "workout-flight-recorder", qos: .utility)

    /// `directory` replaces `Documents/WorkoutLogs/`, for tests.
    init(directory: URL? = nil) {
        self.directory = directory
    }

    /// Starts a new log, dropping anything buffered.
    func begin(at date: Date = Date()) {
        frames = []
        originTimestamp = nil
        originPresentation = nil
        startedAt = date
    }

    /// Buffers one raw frame in its compact on-disk form. Frames past
    /// `maxSeconds` from the first frame are dropped.
    func append(_ raw: RawPoseFrame) {
        let origin = originTimestamp ?? raw.timestamp
        if originTimestamp == nil {
            originTimestamp = raw.timestamp
            originPresentation = raw.presentationTime
        }
        guard raw.timestamp - origin <= Self.maxSeconds else { return }
        frames.append(RecordedFrame(raw: raw, originTimestamp: origin, originPresentationTime: originPresentation))
    }

    var frameCount: Int { frames.count }

    /// Builds the session for what is buffered, nil when there are no frames.
    func makeSession(
        live: LiveResult,
        config: SessionConfig,
        device: DeviceInfo,
        id: String = UUID().uuidString
    ) -> RecordedSession? {
        guard !frames.isEmpty else { return nil }
        return RecordedSession(
            id: id,
            createdAt: RecordedSession.iso8601String(from: startedAt),
            kind: .workout,
            trueReps: nil,
            poseLabel: nil,
            subject: Self.subject,
            tags: RecordedSession.Tags(
                lighting: .indoorBright, distance: .mid, clothing: .fitted,
                tempo: .normal, variant: .standard, cheat: .none
            ),
            notes: config.nonDefaultDescription.joined(separator: "\n"),
            device: device,
            live: live,
            frames: frames,
            countVisible: true
        )
    }

    /// Writes the buffered frames and prunes old logs, off the main queue,
    /// then empties the buffer. Returns without writing when there are no
    /// frames. A failure is dropped: a log is a convenience, never worth
    /// disturbing a workout for.
    func flush(live: LiveResult, config: SessionConfig, device: DeviceInfo) {
        guard let session = makeSession(live: live, config: config, device: device) else { return }
        frames = []
        originTimestamp = nil
        let started = startedAt
        let target = directory
        writeQueue.async {
            guard let folder = try? Self.logsDirectory(override: target) else { return }
            let name = RecordedSession.fileName(kind: .workout, createdAt: started, id: session.id)
            try? session.write(to: folder.appendingPathComponent(name))
            Self.prune(folder, keeping: Self.maxLogs)
        }
    }

    /// `Documents/WorkoutLogs/`, created on demand.
    static func logsDirectory(override: URL? = nil) throws -> URL {
        let url: URL
        if let override {
            url = override
        } else {
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            url = documents.appendingPathComponent("WorkoutLogs", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deletes all but the newest `count` workout logs in `folder`. Only files
    /// whose names `isWorkoutLogFileName` accepts are ever touched; the names
    /// start with a UTC timestamp, so name order is age order.
    static func prune(_ folder: URL, keeping count: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter(RecordedSession.isWorkoutLogFileName)
            .sorted()
        for name in names.dropLast(count) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
#endif
