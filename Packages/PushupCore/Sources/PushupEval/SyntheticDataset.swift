import Foundation
import PushupCore
import PushupSynth

/// The small synthetic dataset written by `pushup-eval synth`: twelve
/// sessions in two sittings, covering clean sets at three tempos and several
/// rep counts, half reps, an arm wave, a mixed set and negative clips. It
/// exists to exercise the harness, not to measure anything.
public enum SyntheticDataset {
    public static let sessionCount = 12

    /// Recording times: one sitting at 10:00 and one at 15:00 on the same day.
    private static let morning = SyntheticSessions.defaultCreatedAt
    private static let afternoon = SyntheticSessions.defaultCreatedAt.addingTimeInterval(5 * 3600)

    public static func sessions(seed: UInt64 = 1) -> [RecordedSession] {
        let bright = SyntheticSessions.Conditions(lighting: .indoorBright, distance: .mid, clothing: .fitted)
        let dim = SyntheticSessions.Conditions(lighting: .dim, distance: .far, clothing: .loose)

        func at(_ base: Date, minute: Int) -> Date { base.addingTimeInterval(Double(minute) * 240) }
        // A distinct generator seed per session, derived from the user's seed.
        func s(_ index: UInt64) -> UInt64 { seed &* 1000 &+ index }

        return [
            SyntheticSessions.cleanSet(reps: 5, tempo: .normal, conditions: bright, createdAt: at(morning, minute: 0), seed: s(0)),
            SyntheticSessions.cleanSet(reps: 8, tempo: .normal, conditions: bright, createdAt: at(morning, minute: 1), seed: s(1), noBodySeconds: 0.4),
            SyntheticSessions.cleanSet(reps: 12, tempo: .slow, conditions: bright, createdAt: at(morning, minute: 2), seed: s(2)),
            SyntheticSessions.cleanSet(reps: 6, tempo: .fast, conditions: bright, createdAt: at(morning, minute: 3), seed: s(3)),
            SyntheticSessions.halfRepSet(reps: 6, conditions: bright, createdAt: at(morning, minute: 4), seed: s(4)),
            SyntheticSessions.negativeClip(conditions: bright, createdAt: at(morning, minute: 5), seed: s(5)),
            SyntheticSessions.cleanSet(reps: 3, tempo: .normal, conditions: dim, createdAt: at(afternoon, minute: 0), seed: s(6)),
            SyntheticSessions.cleanSet(reps: 10, tempo: .normal, conditions: dim, createdAt: at(afternoon, minute: 1), seed: s(7), noBodySeconds: 0.4),
            SyntheticSessions.cleanSet(reps: 15, tempo: .slow, conditions: dim, createdAt: at(afternoon, minute: 2), seed: s(8)),
            SyntheticSessions.mixedSet(validReps: 4, halfReps: 3, conditions: dim, createdAt: at(afternoon, minute: 3), seed: s(9)),
            SyntheticSessions.armWaveSet(reps: 6, conditions: dim, createdAt: at(afternoon, minute: 4), seed: s(10)),
            SyntheticSessions.negativeClip(seconds: 25, conditions: dim, createdAt: at(afternoon, minute: 5), seed: s(11), noBody: 10...12),
        ]
    }

    /// Names accepted by `session(named:seed:)`.
    public static let singleSessionNames = ["clean-8"]

    /// One session picked by name, or nil for an unknown name. `clean-8` is a
    /// single clean set of 8 full reps at normal tempo with the body in frame
    /// throughout, used as the app's bundled demo recording.
    public static func session(named name: String, seed: UInt64 = 1) -> RecordedSession? {
        switch name {
        case "clean-8":
            let bright = SyntheticSessions.Conditions(lighting: .indoorBright, distance: .mid, clothing: .fitted)
            return SyntheticSessions.cleanSet(reps: 8, tempo: .normal, conditions: bright, createdAt: morning, seed: seed)
        default:
            return nil
        }
    }

    /// Writes one named session into `directory` (created if needed) and
    /// returns its file name. Same encoding as `write(to:seed:)`.
    @discardableResult
    public static func writeSession(named name: String, to directory: URL, seed: UInt64 = 1) throws -> String {
        guard let session = session(named: name, seed: seed) else {
            throw EvalError.unknownSession(name, singleSessionNames)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fileName = RecordedSession.fileName(kind: session.kind, createdAt: session.createdAt, id: session.id)
        try encoder.encode(session).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    /// Writes the dataset into `directory` (created if needed), one file per
    /// session named with `RecordedSession.fileName`, and returns the file
    /// names in order.
    @discardableResult
    public static func write(to directory: URL, seed: UInt64 = 1) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `RecordedSession.jsonData()` leaves key order to Foundation, which
        // varies between runs; sorted keys make the files byte-stable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var names: [String] = []
        for session in sessions(seed: seed) {
            let name = RecordedSession.fileName(kind: session.kind, createdAt: session.createdAt, id: session.id)
            try encoder.encode(session).write(to: directory.appendingPathComponent(name), options: .atomic)
            names.append(name)
        }
        return names
    }
}
