import Foundation
import PushupCore
import os.log

/// The saved workouts, newest first: a JSON file in Application Support,
/// loaded at launch and rewritten atomically whenever a record is added.
final class WorkoutHistoryStore: ObservableObject {
    /// The most records kept; the oldest go first.
    static let capacity = 500

    /// Newest first.
    @Published private(set) var records: [WorkoutSessionRecord]

    private let fileURL: URL?
    private static let log = OSLog(subsystem: "com.addymitter.pushuptime", category: "WorkoutHistory")

    /// - Parameter fileURL: where the history lives; nil keeps it in memory only.
    init(fileURL: URL? = WorkoutHistoryStore.defaultFileURL(), showsDemoRecords: Bool = AppEnvironment.current.demoHistory) {
        self.fileURL = fileURL
        let loaded = fileURL.flatMap(Self.load) ?? []
        if loaded.isEmpty, showsDemoRecords {
            records = Self.demoRecords()
        } else {
            records = loaded
        }
    }

    /// Saves a finished workout as the newest record. Demo records, if they
    /// were showing, give way to the real history.
    func add(_ record: WorkoutSessionRecord) {
        var real = records.filter { !Self.demoIDs.contains($0.id) }
        real.insert(record, at: 0)
        if real.count > Self.capacity {
            real.removeLast(real.count - Self.capacity)
        }
        records = real
        persist(real)
    }

    // MARK: Persistence

    static func defaultFileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return support.appendingPathComponent("WorkoutHistory.json")
    }

    private static func load(from url: URL) -> [WorkoutSessionRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([WorkoutSessionRecord].self, from: data)
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            os_log(.error, log: log, "could not read history: %{public}@", String(describing: error))
            return nil
        }
    }

    private func persist(_ records: [WorkoutSessionRecord]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            os_log(.error, log: Self.log, "could not save history: %{public}@", String(describing: error))
        }
    }

    // MARK: Demo data

    private static let demoIDs: Set<UUID> = Set(demoSpec.map(\.id))

    /// For today's entries `hour` and `minute` are how long ago the session
    /// started; for earlier days they are the time of day.
    private static let demoSpec: [(id: UUID, daysAgo: Int, hour: Int, minute: Int, reps: Int, tempo: Double, shallow: Int)] = [
        (UUID(uuidString: "6F1D2C3A-90B4-4C7E-8A55-1B2C3D4E5F60")!, 0, 0, 25, 8, 2.1, 1),
        (UUID(uuidString: "A3B91E47-5D20-4F8B-9C61-7E8F9A0B1C2D")!, 0, 3, 30, 14, 2.4, 0),
        (UUID(uuidString: "0C4E8A12-B7D3-4A59-8E06-3F5A6B7C8D9E")!, 1, 19, 5, 20, 2.2, 3),
        (UUID(uuidString: "D2E5F8A1-3C6B-4D97-A0E4-9B1C2D3E4F5A")!, 2, 8, 30, 12, 2.6, 0),
        (UUID(uuidString: "5B7A9C0E-1D2F-4E3A-B4C5-6D7E8F9A0B1C")!, 3, 17, 40, 16, 2.3, 2),
        (UUID(uuidString: "E8F0A2B4-C6D8-4E0F-9A1B-2C3D4E5F6A7B")!, 4, 20, 15, 10, 2.5, 0),
    ]

    /// Six plausible sessions over the last five days, for screenshots. Never
    /// written to disk.
    private static func demoRecords(now: Date = .now, calendar: Calendar = .current) -> [WorkoutSessionRecord] {
        let today = calendar.startOfDay(for: now)
        return demoSpec.compactMap { spec in
            guard let day = calendar.date(byAdding: .day, value: -spec.daysAgo, to: today),
                  var start = calendar.date(bySettingHour: spec.hour, minute: spec.minute, second: 0, of: day)
            else { return nil }
            if spec.daysAgo == 0 {
                // Today's sessions are placed relative to now so they are
                // never in the future, and never slip into yesterday.
                let minutesAgo = Double(spec.hour * 60 + spec.minute)
                start = max(now.addingTimeInterval(-minutesAgo * 60), today.addingTimeInterval(60))
            }
            let times = (0..<spec.reps).map { 2.0 + Double($0) * spec.tempo }
            return WorkoutSessionRecord(
                id: spec.id,
                startedAt: start,
                durationSeconds: (times.last ?? 0) + 1.5,
                reps: spec.reps,
                repTimes: times,
                shallowAttempts: spec.shallow,
                minutesEarned: spec.reps
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}
