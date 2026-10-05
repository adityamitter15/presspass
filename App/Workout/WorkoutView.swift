import PushupCore
import SwiftUI
import UIKit

/// The workout, presented full screen over Home. Layers back to front: the
/// camera (or a dark placeholder), a scrim top and bottom, the skeleton, then
/// the HUD for the current phase. After a set it turns into the summary.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var summary: WorkoutSessionRecord?
    @State private var didFinish = false
    @State private var didStart = false
    #if DEBUG
    @AppStorage(AppSettings.Key.debugOverlay) private var debugOverlay = false
    #endif

    init(launch: Launch = .live) {
        self.launch = launch
    }

    /// The part of the phase that decides which HUD shows, without the countdown value.
    private enum HUDKind: Equatable { case positioning, active, finishing, finished }

    private var hudKind: HUDKind {
        switch viewModel.phase {
        case .positioning: .positioning
        case .active: .active
        case .finishing: .finishing
        case .finished: .finished
        }
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
                    hud
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
            scrim
            SkeletonOverlayView(frame: viewModel.latestFrame)
                .ignoresSafeArea()
                .opacity(summary == nil ? 0.85 : 0.35)
        }
        .accessibilityHidden(true)
    }

    /// Darkens the top, where the numeral sits, and the bottom, where the
    /// controls sit, so the HUD reads over a bright camera image.
    private var scrim: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.72), location: 0),
                    .init(color: .black.opacity(0.5), location: 0.45),
                    .init(color: .black.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxHeight: .infinity)
            Spacer(minLength: 0).frame(maxHeight: .infinity)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.55),
                    .init(color: .black.opacity(0.78), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: HUD

    private var hud: some View {
        ZStack {
            switch hudKind {
            case .positioning:
                PositioningCard(
                    bodyInFrame: viewModel.isBodyDetected,
                    handsOnFloor: viewModel.isPostureValid,
                    progress: viewModel.holdProgress
                )
                .padding(.horizontal, Theme.Space.xl)
                .transition(.popIn(reduceMotion: reduceMotion))
            case .active:
                ActiveHUD(viewModel: viewModel)
                    .transition(.opacity)
            case .finishing:
                FinishingHUD(
                    secondsRemaining: secondsRemaining,
                    reps: viewModel.reps
                )
                .transition(.popIn(reduceMotion: reduceMotion, scale: 0.95))
            case .finished:
                EmptyView()
            }

            VStack {
                #if DEBUG
                if debugOverlay { debugHUD }
                #endif
                Spacer()
                bottomButton
            }
            .padding(.bottom, Theme.Space.l)
            .padding(.horizontal, Theme.Space.xl)
        }
        .motion(.smooth, value: hudKind)
    }

    private var secondsRemaining: Double {
        if case .finishing(let seconds) = viewModel.phase { return seconds }
        return 0
    }

    @ViewBuilder
    private var bottomButton: some View {
        switch hudKind {
        case .positioning:
            GlassButton("Cancel") { viewModel.requestFinish() }
        case .active:
            GlassButton("Finish") { viewModel.requestFinish() }
        case .finishing:
            GlassButton("Finish now") { viewModel.requestFinish() }
        case .finished:
            EmptyView()
        }
    }

    #if DEBUG
    private var debugHUD: some View {
        Text(viewModel.debugStatus)
            .font(.caption2.monospaced())
            .foregroundStyle(.yellow)
            .padding(Theme.Space.s)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
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

// MARK: - Positioning

/// "Get into position": a card with two checks that tick live and a ring
/// that fills over the start hold.
private struct PositioningCard: View {
    let bodyInFrame: Bool
    let handsOnFloor: Bool
    let progress: Double

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            ProgressRing(progress: progress, diameter: 104, lineWidth: 10) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hold position")
            .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")

            VStack(spacing: Theme.Space.xs) {
                Text("Get into position")
                    .font(Theme.title(.title2))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Phone on the floor, about a metre in front of you")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CheckRow(title: "Body in frame", isDone: bodyInFrame)
                CheckRow(title: "Hands on the floor", isDone: handsOnFloor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 340)
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

private struct CheckRow: View {
    let title: String
    let isDone: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isDone ? Theme.volt : Theme.textTertiary)
                .contentTransition(.symbolEffect(.replace))
                .motion(.pop, value: isDone)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(isDone ? Theme.textPrimary : Theme.textSecondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isDone ? "Done" : "Not yet")
    }
}

// MARK: - Active

/// The count, wrapped in the depth ring, with the time and minutes quietly
/// underneath, and the hint in the lower third.
private struct ActiveHUD: View {
    @ObservedObject var viewModel: WorkoutViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let diameter = min(300, geo.size.width - Theme.Space.xl * 2)
            let scale = diameter / 300
            ZStack {
                VStack(spacing: Theme.Space.l) {
                    DepthRing(
                        depth: viewModel.depth,
                        rippleTrigger: viewModel.reps,
                        isShallow: viewModel.ringState == .shallow,
                        diameter: diameter,
                        lineWidth: 22 * scale
                    ) {
                        ZStack {
                            RepNumeral(value: viewModel.reps, size: 190 * scale)
                                .opacity(viewModel.showsGo ? 0 : 1)
                            if viewModel.showsGo {
                                Text("Go")
                                    .font(Theme.heroNumeral(size: 130 * scale))
                                    .foregroundStyle(Theme.volt)
                                    .shadow(color: Theme.volt.opacity(0.5), radius: 18)
                                    .transition(.popIn(reduceMotion: reduceMotion, scale: 0.7))
                                    .accessibilityLabel("Go")
                            }
                        }
                        .motion(.pop, value: viewModel.showsGo)
                    }

                    HStack(spacing: Theme.Space.m) {
                        Text(Self.clock(viewModel.elapsedSeconds))
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityLabel("Time \(viewModel.elapsedSeconds) seconds")
                        Text("+\(viewModel.minutesEarned) min")
                            .foregroundStyle(Theme.volt)
                            .contentTransition(.numericText(value: Double(viewModel.minutesEarned)))
                            .motion(.pop, value: viewModel.minutesEarned)
                    }
                    .font(.system(.headline, design: .rounded, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                    .frame(minHeight: 44)
                    .glassSurface(in: Capsule())
                }
                .position(x: geo.size.width / 2, y: geo.size.height * 0.33 + 20)

                ZStack {
                    if let hint = viewModel.hint {
                        HintPill(systemImage: hint.systemImage, text: hint.text, tone: hint.tone)
                            .id(hint)
                            .transition(.popIn(reduceMotion: reduceMotion, scale: 0.92))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Space.xl)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.76)
                .motion(.pop, value: viewModel.hint)
            }
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Finishing

/// The person has left the posture: a countdown to the automatic finish.
private struct FinishingHUD: View {
    let secondsRemaining: Double
    let reps: Int

    private var wholeSeconds: Int { max(Int(secondsRemaining.rounded(.up)), 0) }

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            ProgressRing(
                progress: secondsRemaining / WorkoutFlow.Config.default.finishingCountdown,
                diameter: 220,
                lineWidth: 16
            ) {
                Text("\(wholeSeconds)")
                    .font(Theme.heroNumeral(size: 110))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText(countsDown: true))
                    .motion(.pop, value: wholeSeconds)
                    .shadow(color: .black.opacity(0.4), radius: 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Finishing in")
            .accessibilityValue("\(wholeSeconds) seconds")

            VStack(spacing: Theme.Space.xs) {
                Text("Get back down to keep going")
                    .font(Theme.title(.title3))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("\(reps) \(reps == 1 ? "press-up" : "press-ups"), +\(reps) min")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Space.xl)
        }
        .offset(y: -40)
    }
}

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
        }
    }

    private var message: String {
        switch issue {
        case .notAuthorized:
            "The front camera is how PressPass counts your press-ups. Turn it on in Settings and come straight back."
        case .unavailable:
            "PressPass counts press-ups with the front camera, and this device does not have one it can use."
        }
    }
}
