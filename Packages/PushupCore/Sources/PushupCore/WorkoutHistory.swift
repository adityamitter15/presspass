import Foundation

/// One finished workout, as stored in the history and shown on a pass.
public struct WorkoutSessionRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    /// When the set became active.
    public var startedAt: Date
    /// Seconds from the start of the set to its last counted rep or its last
    /// moment in position, whichever is later.
    public var durationSeconds: Double
    public var reps: Int
    /// Seconds since the start of the set at which each rep was counted.
    public var repTimes: [Double]
    /// Descents that began but were not low enough to count.
    public var shallowAttempts: Int
    public var minutesEarned: Int

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        durationSeconds: Double,
        reps: Int,
        repTimes: [Double],
        shallowAttempts: Int,
        minutesEarned: Int
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.reps = reps
        self.repTimes = repTimes
        self.shallowAttempts = shallowAttempts
        self.minutesEarned = minutesEarned
    }
}

/// Reps on one calendar day, for `WorkoutStats.repsPerDay`.
public struct DayTotal: Equatable {
    /// The start of the day in the calendar used to compute it.
    public let day: Date
    public let reps: Int

    public init(day: Date, reps: Int) {
        self.day = day
        self.reps = reps
    }
}

/// Pure statistics over workout records. Every function takes the current
/// time and calendar so the day boundaries are explicit and testable.
public enum WorkoutStats {
    /// Total reps of the records that started on the same calendar day as `now`.
    public static func repsToday(
        _ records: [WorkoutSessionRecord],
        now: Date,
        calendar: Calendar
    ) -> Int {
        records
            .filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
            .reduce(0) { $0 + $1.reps }
    }

    /// Consecutive calendar days with at least one rep. The run ends today, or
    /// yesterday when today has no rep yet (the streak is still alive until
    /// the day is over). Zero when neither today nor yesterday has a rep.
    public static func currentStreak(
        _ records: [WorkoutSessionRecord],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let activeDays = Set(
            records.filter { $0.reps > 0 }.map { calendar.startOfDay(for: $0.startedAt) }
        )
        let today = calendar.startOfDay(for: now)
        guard var cursor = Self.streakStart(today: today, activeDays: activeDays, calendar: calendar) else {
            return 0
        }
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    private static func streakStart(today: Date, activeDays: Set<Date>, calendar: Calendar) -> Date? {
        if activeDays.contains(today) { return today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              activeDays.contains(yesterday) else { return nil }
        return yesterday
    }

    /// Reps for each of the last `lastDays` calendar days, oldest first,
    /// ending with today. Days without a workout are present with 0 reps.
    public static func repsPerDay(
        _ records: [WorkoutSessionRecord],
        lastDays: Int,
        now: Date,
        calendar: Calendar
    ) -> [DayTotal] {
        guard lastDays > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var totals: [Date: Int] = [:]
        for record in records {
            totals[calendar.startOfDay(for: record.startedAt), default: 0] += record.reps
        }
        return (0..<lastDays).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayTotal(day: day, reps: totals[day] ?? 0)
        }
    }

    /// Reps per minute from the first to the last counted rep: the gaps
    /// between reps, not the time spent getting into position. Nil for fewer
    /// than two reps, or when the first and last rep share a timestamp.
    public static func averageTempo(of repTimes: [Double]) -> Double? {
        guard let first = repTimes.min(), let last = repTimes.max(), repTimes.count >= 2, last > first else {
            return nil
        }
        return Double(repTimes.count - 1) / (last - first) * 60
    }

    public static func averageTempo(of record: WorkoutSessionRecord) -> Double? {
        averageTempo(of: record.repTimes)
    }
}
