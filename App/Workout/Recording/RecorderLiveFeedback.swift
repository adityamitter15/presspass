#if DEBUG
import Foundation
import PushupCore

/// What the recorder's live screen shows while a take runs: the depth of the
/// ring and, only when the person chose to see it, the app's rep count with
/// the same sounds the workout makes. It reads the pipeline's output and never
/// feeds anything back, and it does not touch what is recorded. In a blind
/// take it publishes depth and nothing else: no count, no shallow flash and
/// no sound, so no signal about the app's counting reaches the person.
@MainActor
final class RecorderLiveFeedback {
    struct Snapshot: Equatable {
        /// 0 (arms straight) to 1 (low enough to count).
        var depth: Double = 0
        /// The app's count, or 0 for ever in a blind take.
        var reps: Int = 0
        /// A shallow attempt is being flashed. Never true in a blind take.
        var isShallow = false
    }

    private static let shallowSeconds: TimeInterval = 1.0

    private var tracker = DepthTracker()
    private var audio: WorkoutAudio?
    private var countVisible = false
    private var shallowUntil: TimeInterval = 0
    private(set) var snapshot = Snapshot()

    /// Starts a take. Sound only runs when the count is visible.
    func begin(countVisible: Bool) {
        self.countVisible = countVisible
        tracker.reset()
        shallowUntil = 0
        snapshot = Snapshot()
        audio?.end()
        audio = nil
        if countVisible {
            let audio = WorkoutAudio(mode: AppSettings.soundMode)
            audio.begin()
            self.audio = audio
        }
    }

    /// Feeds one frame's output. `repsBefore` is the app's count before it.
    func process(_ output: PipelineOutput, repsBefore: Int, timestamp: TimeInterval) {
        let event = tracker.update(with: output, repsBefore: repsBefore)
        var next = snapshot
        next.depth = Double(tracker.depth)
        guard countVisible else {
            if next != snapshot { snapshot = next }
            return
        }
        next.reps = output.reps
        if output.reps > repsBefore { audio?.rep(output.reps) }
        if case .shallowAttempt = event {
            shallowUntil = timestamp + Self.shallowSeconds
            audio?.shallowAttempt()
        }
        next.isShallow = timestamp < shallowUntil
        if abs(next.depth - snapshot.depth) > 0.002 || next.reps != snapshot.reps || next.isShallow != snapshot.isShallow {
            snapshot = next
        }
    }

    /// Ends the take: stops sound and clears the display.
    func end() {
        audio?.end()
        audio = nil
        countVisible = false
        snapshot = Snapshot()
    }
}
#endif
