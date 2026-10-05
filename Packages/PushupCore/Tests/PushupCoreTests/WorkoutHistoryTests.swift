import Foundation
import Testing
import PushupCore

/// A fixed Gregorian calendar in a fixed time zone with a fixed first weekday,
/// so no test depends on where or when it runs.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.firstWeekday = 2
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func record(_ start: Date, reps: Int, repTimes: [Double]? = nil) -> WorkoutSessionRecord {
    WorkoutSessionRecord(
        startedAt: start,
        durationSeconds: Double(reps) * 2,
        reps: reps,
        repTimes: repTimes ?? (0..<reps).map { Double($0) * 2 },
        shallowAttempts: 0,
        minutesEarned: reps
    )
}

@Suite("WorkoutSessionRecord")
struct WorkoutSessionRecordTests {
    @Test("a record survives a JSON round trip")
    func codable() throws {
        let original = WorkoutSessionRecord(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            durationSeconds: 31.5,
            reps: 3,
            repTimes: [2.0, 4.1, 6.3],
            shallowAttempts: 2,
            minutesEarned: 3
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutSessionRecord.self, from: data)
        #expect(decoded == original)
    }

    @Test("each record gets its own id")
    func identity() {
        let a = record(date(2026, 3, 10), reps: 1)
        let b = record(date(2026, 3, 10), reps: 1)
        #expect(a.id != b.id)
    }
}

@Suite("WorkoutStats.repsToday")
struct RepsTodayTests {
    @Test("no records means no reps")
    func empty() {
        #expect(WorkoutStats.repsToday([], now: date(2026, 3, 10), calendar: calendar) == 0)
    }

    @Test("sums every session on the same calendar day")
    func sums() {
        let records = [
            record(date(2026, 3, 10, 7, 30), reps: 10),
            record(date(2026, 3, 10, 21, 5), reps: 5),
            record(date(2026, 3, 9, 20), reps: 40),
        ]
        #expect(WorkoutStats.repsToday(records, now: date(2026, 3, 10, 9), calendar: calendar) == 15)
    }

    @Test("the day boundary is local midnight: 23:59 and 00:00 are different days")
    func dayBoundary() {
        let lateLastNight = record(date(2026, 3, 9, 23, 59), reps: 7)
        let justAfterMidnight = record(date(2026, 3, 10, 0, 0), reps: 4)
        let now = date(2026, 3, 10, 0, 1)
        #expect(WorkoutStats.repsToday([lateLastNight, justAfterMidnight], now: now, calendar: calendar) == 4)
    }

    @Test("a session on a later day does not count towards today")
    func laterDay() {
        let tomorrow = record(date(2026, 3, 11, 0, 0), reps: 9)
        #expect(WorkoutStats.repsToday([tomorrow], now: date(2026, 3, 10, 23, 59), calendar: calendar) == 0)
    }

    @Test("days follow the calendar's time zone, not UTC")
    func timeZone() {
        // 00:30 on 1 July in London is still 30 June in UTC.
        let record = record(date(2026, 7, 1, 0, 30), reps: 6)
        #expect(WorkoutStats.repsToday([record], now: date(2026, 7, 1, 12), calendar: calendar) == 6)
    }
}

@Suite("WorkoutStats.currentStreak")
struct CurrentStreakTests {
    @Test("no records means no streak")
    func empty() {
        #expect(WorkoutStats.currentStreak([], now: date(2026, 3, 10), calendar: calendar) == 0)
    }

    @Test("only today is a streak of one")
    func onlyToday() {
        let records = [record(date(2026, 3, 10, 8), reps: 3)]
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 20), calendar: calendar) == 1)
    }

    @Test("consecutive days ending today")
    func endingToday() {
        let records = [10, 9, 8, 7].map { record(date(2026, 3, $0, 8), reps: 2) }
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 20), calendar: calendar) == 4)
    }

    @Test("a streak with no workout yet today is still alive when yesterday had one")
    func endingYesterday() {
        let records = [9, 8, 7].map { record(date(2026, 3, $0, 8), reps: 2) }
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 7), calendar: calendar) == 3)
    }

    @Test("a missed day yesterday ends the streak, even with a workout two days ago")
    func brokenStreak() {
        let records = [record(date(2026, 3, 8, 8), reps: 5), record(date(2026, 3, 7, 8), reps: 5)]
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 12), calendar: calendar) == 0)
    }

    @Test("a gap in the middle stops the count at the gap")
    func gapInMiddle() {
        let records = [10, 9, 7, 6].map { record(date(2026, 3, $0, 8), reps: 2) }
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 12), calendar: calendar) == 2)
    }

    @Test("several sessions on one day count as one day")
    func manySessionsOneDay() {
        let records = [
            record(date(2026, 3, 10, 6), reps: 2),
            record(date(2026, 3, 10, 12), reps: 2),
            record(date(2026, 3, 9, 22), reps: 2),
        ]
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 23), calendar: calendar) == 2)
    }

    @Test("a record with zero reps does not keep a streak alive")
    func zeroRepRecord() {
        let records = [record(date(2026, 3, 10, 8), reps: 0), record(date(2026, 3, 9, 8), reps: 4)]
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 12), calendar: calendar) == 1)
    }

    @Test("a streak runs across a month and year boundary")
    func acrossMonthAndYear() {
        let records = [
            record(date(2026, 1, 2, 8), reps: 1),
            record(date(2026, 1, 1, 23, 59), reps: 1),
            record(date(2025, 12, 31, 0, 1), reps: 1),
            record(date(2025, 12, 30, 12), reps: 1),
        ]
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 1, 2, 9), calendar: calendar) == 4)
    }

    @Test("a streak runs across the clocks going forward")
    func acrossDaylightSaving() {
        // The UK clocks went forward on 29 March 2026, a 23 hour day.
        let records = [28, 29, 30].map { record(date(2026, 3, $0, 8), reps: 2) }
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 30, 12), calendar: calendar) == 3)
    }

    @Test("a late night session and an early morning session are two separate days")
    func midnightSplit() {
        let records = [record(date(2026, 3, 9, 23, 59), reps: 2), record(date(2026, 3, 10, 0, 1), reps: 2)]
        #expect(WorkoutStats.currentStreak(records, now: date(2026, 3, 10, 12), calendar: calendar) == 2)
    }
}

@Suite("WorkoutStats.repsPerDay")
struct RepsPerDayTests {
    @Test("returns one entry per day, oldest first, ending today, with empty days as zero")
    func shape() {
        let records = [
            record(date(2026, 3, 10, 8), reps: 5),
            record(date(2026, 3, 10, 18), reps: 3),
            record(date(2026, 3, 8, 8), reps: 6),
        ]
        let totals = WorkoutStats.repsPerDay(records, lastDays: 4, now: date(2026, 3, 10, 20), calendar: calendar)
        #expect(totals.map(\.reps) == [0, 6, 0, 8])
        #expect(totals.map(\.day) == [7, 8, 9, 10].map { date(2026, 3, $0, 0, 0) })
    }

    @Test("records older than the window are left out")
    func windowEdge() {
        let records = [record(date(2026, 3, 6, 23, 59), reps: 9), record(date(2026, 3, 7, 0, 0), reps: 2)]
        let totals = WorkoutStats.repsPerDay(records, lastDays: 4, now: date(2026, 3, 10, 12), calendar: calendar)
        #expect(totals.map(\.reps) == [2, 0, 0, 0])
    }

    @Test("a window of zero or fewer days is empty")
    func emptyWindow() {
        #expect(WorkoutStats.repsPerDay([], lastDays: 0, now: date(2026, 3, 10), calendar: calendar).isEmpty)
        #expect(WorkoutStats.repsPerDay([], lastDays: -3, now: date(2026, 3, 10), calendar: calendar).isEmpty)
    }

    @Test("a window across the end of a month lists the right dates")
    func acrossMonth() {
        let totals = WorkoutStats.repsPerDay([], lastDays: 3, now: date(2026, 3, 1, 12), calendar: calendar)
        #expect(totals.map(\.day) == [date(2026, 2, 27, 0, 0), date(2026, 2, 28, 0, 0), date(2026, 3, 1, 0, 0)])
    }
}

@Suite("WorkoutStats.averageTempo")
struct AverageTempoTests {
    @Test("fewer than two reps has no tempo", arguments: [[], [3.0]] as [[Double]])
    func tooFew(repTimes: [Double]) {
        #expect(WorkoutStats.averageTempo(of: repTimes) == nil)
    }

    @Test("two seconds between reps is 30 reps per minute")
    func steady() throws {
        let tempo = try #require(WorkoutStats.averageTempo(of: [2, 4, 6, 8]))
        #expect(abs(tempo - 30) < 1e-9)
    }

    @Test("the lead-in before the first rep and the idle time after the last do not matter")
    func ignoresLeadIn() throws {
        let early = try #require(WorkoutStats.averageTempo(of: [1, 3, 5]))
        let late = try #require(WorkoutStats.averageTempo(of: [31, 33, 35]))
        #expect(abs(early - late) < 1e-9)
    }

    @Test("two reps one second apart is 60 reps per minute")
    func twoReps() throws {
        let tempo = try #require(WorkoutStats.averageTempo(of: [5, 6]))
        #expect(abs(tempo - 60) < 1e-9)
    }

    @Test("reps at the same instant have no tempo")
    func degenerate() {
        #expect(WorkoutStats.averageTempo(of: [4, 4]) == nil)
    }

    @Test("reads the rep times from a record")
    func fromRecord() throws {
        let tempo = try #require(WorkoutStats.averageTempo(of: record(date(2026, 3, 10), reps: 4, repTimes: [0, 3, 6, 9])))
        #expect(abs(tempo - 20) < 1e-9)
        #expect(WorkoutStats.averageTempo(of: record(date(2026, 3, 10), reps: 1, repTimes: [2])) == nil)
    }
}
