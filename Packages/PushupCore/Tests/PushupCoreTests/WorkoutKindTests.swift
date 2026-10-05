import Foundation
import Testing
import PushupCore
import PushupSynth

@Suite("Workout log kind")
struct WorkoutKindTests {
    private func workoutSession() -> RecordedSession {
        var session = SyntheticSessions.cleanSet(reps: 2, options: .foreshortened())
        session.kind = .workout
        session.trueReps = nil
        session.subject = "app"
        session.live = LiveResult(reps: 2, rejectedReps: 0, classifier: "heuristic")
        return session
    }

    @Test("the raw value is workout, and the recorder's list of kinds does not offer it")
    func rawValue() {
        #expect(RecordedSession.Kind.workout.rawValue == "workout")
        #expect(RecordedSession.Kind(rawValue: "workout") == .workout)
        #expect(RecordedSession.Kind.allCases == [.set, .negative, .pose])
    }

    @Test("a workout log is named workout_ and is not a recording file name")
    func fileNames() {
        let session = workoutSession()
        let name = RecordedSession.fileName(kind: session.kind, createdAt: session.createdAt, id: session.id)
        #expect(name.hasPrefix("workout_") && name.hasSuffix(".json"))
        #expect(RecordedSession.isWorkoutLogFileName(name))
        #expect(!RecordedSession.isRecordingFileName(name))
        #expect(!RecordedSession.isRecordingVideoFileName(name.replacingOccurrences(of: ".json", with: ".mp4")))
        #expect(!RecordedSession.isWorkoutLogFileName("set_20260704-093015_3f2504e0.json"))
        #expect(!RecordedSession.isWorkoutLogFileName("../workout_20260704-093015_3f2504e0.json"))
        #expect(!RecordedSession.isWorkoutLogFileName("workout_20260704-093015_3f2504e0.json.bak"))
    }

    @Test("a workout log survives a JSON round trip with no true count")
    func roundTrip() throws {
        let session = workoutSession()
        let decoded = try RecordedSession.decode(session.jsonData())
        #expect(decoded == session)
        #expect(decoded.kind == .workout && decoded.trueReps == nil)
    }

    @Test("a workout log can be replayed through the engine")
    func replayable() {
        let session = workoutSession()
        let engine = WorkoutSessionEngine()
        for frame in session.poseFrames() { engine.process(frame) }
        #expect(engine.reps == 2)
    }
}
