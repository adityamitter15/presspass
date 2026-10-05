import PushupCore
import SwiftUI
import UIKit

/// The workout, presented full screen over Home. Layers back to front: the
/// camera (or a dark placeholder), a scrim, the skeleton, then the HUD. After
/// a set it turns into the summary.
struct WorkoutView: View {
    /// How the cover opens: a live workout, or (DEBUG screenshots) straight
    /// onto the summary of a finished one.
    enum Launch: Equatable {
        case live
        case demoSummary(WorkoutSessionRecord)
    }

    let launch: Launch

    @StateObject private var viewModel = WorkoutViewModel()
    @EnvironmentObject private var history: WorkoutHistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var summary: WorkoutSessionRecord?
    @State private var didFinish = false
    @State private var didStart = false
    #if DEBUG
    @AppStorage(AppSettings.Key.debugOverlay) private var debugOverlay = false
    #endif

    init(launch: Launch = .live) {
        self.launch = launch
    }

    var body: some View {
        ZStack {
            if viewModel.cameraIssue == nil {
                cameraLayers
                if let summary {
                    WorkoutSummaryView(
                        record: summary,
                        canUseMinutes: SharedStore.loadSelection() != nil,
                        onUseMinutes: useMinutes,
                        onDone: { dismiss() }
                    )
                } else {
                    WorkoutHUD(
                        viewModel: viewModel,
                        showsDebugOverlay: showsDebugOverlay
                    )
                }
            }
            if let issue = viewModel.cameraIssue {
                CameraIssueView(issue: issue) { dismiss() }
            }
        }
        .background(Theme.ink900.ignoresSafeArea())
        .interactiveDismissDisabled()
        .task { startIfNeeded() }
        .onChange(of: viewModel.phase) { _, phase in
            if phase == .finished { finishWorkout() }
        }
        .onDisappear { viewModel.stop() }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: viewModel.reps)
        .sensoryFeedback(.warning, trigger: viewModel.shallowAttempts)
    }

    private var showsDebugOverlay: Bool {
        #if DEBUG
        debugOverlay
        #else
        false
        #endif
    }

    // MARK: Lifecycle

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        switch launch {
        case .live:
            viewModel.start()
        case .demoSummary(let record):
            didFinish = true
            summary = record
        }
    }

    /// Stops the source, credits the minutes, saves the record and shows the
    /// summary. A set with no reps saves nothing and just closes.
    private func finishWorkout() {
        guard !didFinish else { return }
        didFinish = true
        guard let record = viewModel.finish() else {
            dismiss()
            return
        }
        SharedStore.credit(minutes: record.reps)
        history.add(record)
        summary = record
    }

    private func useMinutes() {
        try? MeteringCoordinator.startEarnedSession()
        dismiss()
    }

    // MARK: Layers

    private var cameraLayers: some View {
        ZStack {
            CameraPreviewView(previewLayer: viewModel.previewLayer)
                .ignoresSafeArea()
            backdrop
            scrim
            SkeletonOverlayView(frame: viewModel.latestFrame)
                .ignoresSafeArea()
                .opacity(summary == nil ? 1 : 0.35)
        }
        .accessibilityHidden(true)
    }

    /// DEBUG QA aid: a still camera frame behind the skeleton in place of the
    /// dark placeholder, from `-demoBackdrop`. It is shown aspect fill, the
    /// same way the live camera preview is, so the skeleton lands on the
    /// person in the image just as it would on a phone.
    @ViewBuilder
    private var backdrop: some View {
        #if DEBUG
        if viewModel.previewLayer == nil, let image = AppEnvironment.demoBackdropImage {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
        }
        #endif
    }

    /// One gradient over the whole screen. Light at the top so chips and
    /// buttons read on a white wall, nothing over the person band (28 to 64
    /// percent of the height), and a long ramp to ink at the bottom so the
    /// ring reads on a pale floor.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.5), location: 0),
                .init(color: .black.opacity(0), location: WorkoutLayout.personTop),
                .init(color: Theme.ink900.opacity(0), location: 0.58),
                .init(color: Theme.ink900.opacity(0.8), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Demo summary (DEBUG)

#if DEBUG
extension WorkoutView {
    /// A finished-set record built by running the bundled demo session through
    /// the pipeline at once, for `-screen summary`. Nothing is credited or
    /// saved. It always carries two shallow attempts so the summary's layout
    /// with that line is the one checked.
    static func demoSummaryRecord() -> WorkoutSessionRecord? {
        guard let session = AppEnvironment.current.loadDemoSession() else { return nil }
        let pipeline = PushupPipeline(classifier: PoseClassifierFactory.makeDefault())
        var tracker = DepthTracker()
        var reps = 0
        var times: [Double] = []
        var shallow = 0
        let frames = session.poseFrames()
        let start = frames.first?.timestamp ?? 0
        for frame in frames {
            let before = reps
            let output = pipeline.process(frame)
            reps = output.reps
            if reps > before { times.append(frame.timestamp - start) }
            if case .shallowAttempt = tracker.update(with: output, repsBefore: before) { shallow += 1 }
        }
        return WorkoutSessionRecord(
            startedAt: .now,
            durationSeconds: (frames.last?.timestamp ?? start) - start,
            reps: reps,
            repTimes: times,
            shallowAttempts: max(shallow, 2),
            minutesEarned: reps
        )
    }
}
#endif

// MARK: - Camera trouble

/// A friendly full-screen state for a camera that cannot start.
private struct CameraIssueView: View {
    let issue: CameraIssue
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer()
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.coral)
                .frame(width: 104, height: 104)
                .background(Circle().fill(Theme.ink700))
                .accessibilityHidden(true)

            VStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(Theme.title(.title2))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Space.xl)

            Spacer()

            VStack(spacing: Theme.Space.m) {
                if issue == .notAuthorized {
                    PrimaryButton("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                GlassButton("Close", action: onClose)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink900.ignoresSafeArea())
    }

    private var title: String {
        switch issue {
        case .notAuthorized: "PressPass needs your camera"
        case .unavailable: "No front camera found"
        case .interrupted: "The camera is paused"
        }
    }

    private var message: String {
        switch issue {
        case .notAuthorized:
            "The front camera is how PressPass counts your press-ups. Turn it on in Settings and come straight back."
        case .unavailable:
            "PressPass counts press-ups with the front camera, and this device does not have one it can use."
        case .interrupted(let reason):
            reason
        }
    }
}
