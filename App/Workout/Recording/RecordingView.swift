#if DEBUG
import PushupCore
import SwiftUI
import UIKit

/// DEBUG-only data-collection mode, presented full screen from Home. Records
/// full press-up sets, negatives (things that must not count) and held poses
/// as raw landmark streams, each with a human-entered ground truth and
/// condition tags, in the versioned schema documented in
/// `docs/data-format.md`. Four stages: set up, record (full screen, like the
/// workout), label the take, and the saved takes. Not reachable from Release
/// builds.
struct RecordingView: View {
    /// Where a screenshot launch starts (`-screen recorder...`).
    enum Launch: String, Identifiable {
        case setup, recording, label, list

        var id: String { rawValue }
    }

    enum Route: Hashable { case takes }

    let launch: Launch

    @StateObject private var viewModel = RecordingViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var didStartDemo = false

    init(launch: Launch = .setup) {
        self.launch = launch
        Self.applyDemoDefaults(for: launch)
    }

    private var isTakeActive: Bool { viewModel.isRecording || viewModel.isFinalizing }

    var body: some View {
        ZStack {
            if isTakeActive {
                RecorderLiveView(viewModel: viewModel)
                    .transition(.opacity)
            } else {
                NavigationStack(path: $path) {
                    RecorderSetupView(
                        viewModel: viewModel,
                        onClose: close,
                        onOpenTakes: { path.append(.takes) }
                    )
                    .navigationDestination(for: Route.self) { _ in
                        RecorderTakesView(viewModel: viewModel, opensEditOnAppear: launch == .list && AppEnvironment.current.recorderOpensEdit)
                    }
                }
                .transition(.opacity)
            }
        }
        .background(Theme.ink900.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.volt)
        .sheet(item: Binding(get: { viewModel.pendingTake }, set: { _ in })) { take in
            RecorderLabelSheet(
                take: take,
                isSaving: viewModel.isSaving,
                errorMessage: viewModel.errorMessage,
                onTagsChange: { viewModel.updatePendingTags($0) },
                onSave: { viewModel.savePending(trueReps: $0) },
                onDiscard: { viewModel.discardPending() }
            )
        }
        .onAppear {
            // The phone sits untouched on the floor during a set.
            UIApplication.shared.isIdleTimerDisabled = true
            viewModel.refreshSaved()
            viewModel.startCamera()
            if launch == .list { path = [.takes] }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            viewModel.stopCamera()
        }
        .task { await driveDemo() }
    }

    // MARK: Closing

    /// Setup is only on screen between takes, and a take waiting for its
    /// label sits under a sheet that cannot be dismissed, so nothing is lost
    /// here. Leaving mid-take is the live screen's Cancel take.
    private func close() {
        viewModel.stopCamera()
        dismiss()
    }

    // MARK: Screenshot launches

    /// Puts the setup into a known state for `-screen recorder...` launches,
    /// once per process, so every shot starts the same whatever ran before.
    private static var didApplyDefaults = false
    private static func applyDemoDefaults(for launch: Launch) {
        guard AppEnvironment.current.initialScreen?.rawValue.hasPrefix("recorder") == true,
              !didApplyDefaults else { return }
        didApplyDefaults = true
        let defaults = UserDefaults.standard
        let environment = AppEnvironment.current
        defaults.set(RecordedSession.Kind.set.rawValue, forKey: RecorderPrefs.kind)
        defaults.set("S07", forKey: RecorderPrefs.subject)
        defaults.set(RecordedSession.Tags.Hands.knuckles.rawValue, forKey: RecorderPrefs.hands)
        defaults.set(RecordedSession.Tags.Support.knees.rawValue, forKey: RecorderPrefs.support)
        defaults.set(RecordedSession.Tags.Width.normal.rawValue, forKey: RecorderPrefs.width)
        defaults.set(RecordedSession.Tags.Tempo.normal.rawValue, forKey: RecorderPrefs.tempo)
        defaults.set((environment.recorderCheat ?? .none).rawValue, forKey: RecorderPrefs.cheat)
        defaults.set(environment.recorderCountVisible ?? true, forKey: RecorderPrefs.countVisible)
        defaults.set("Wooden floor", forKey: RecorderPrefs.notes)
    }

    /// Starts (and for the label shot, stops) a take by itself, a beat after
    /// the screen opens and the replay is running.
    private func driveDemo() async {
        guard !didStartDemo, launch == .recording || launch == .label else { return }
        didStartDemo = true
        try? await Task.sleep(for: .seconds(1.2))
        viewModel.start(setup: RecorderPrefs.currentSetup())
        if launch == .label {
            try? await Task.sleep(for: .seconds(6))
            viewModel.stop()
        }
    }
}
#endif
