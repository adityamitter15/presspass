import PushupCore
import SwiftUI

/// Today at a glance, the passes earned so far, and the Start button.
struct HomeView: View {
    @EnvironmentObject private var history: WorkoutHistoryStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoomNamespace

    @State private var showWorkout = false
    @State private var showSettings = false
    @State private var balanceMinutes = 0
    @State private var didApplyLaunchScreen = false
    @State private var launchMode: WorkoutView.Launch = .live
    #if DEBUG
    /// Non-nil while the recorder is open full screen.
    @State private var recorderLaunch: RecordingView.Launch?
    @State private var openRecorderAfterSettings = false
    #endif

    private static let zoomID = "start-workout"

    var body: some View {
        let now = Date.now
        let calendar = Calendar.current
        let today = WorkoutStats.repsToday(history.records, now: now, calendar: calendar)
        let streak = WorkoutStats.currentStreak(history.records, now: now, calendar: calendar)

        VStack(spacing: 0) {
            hero(today: today)
            chips(streak: streak)
                .padding(.top, Theme.Space.xl)
            passes
                .padding(.top, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { startArea }
        .background { backdrop }
        .toolbar { toolbar }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showWorkout) {
            WorkoutView(launch: launchMode)
                .navigationTransition(.zoom(sourceID: Self.zoomID, in: zoomNamespace))
        }
        .sheet(isPresented: $showSettings, onDismiss: settingsDismissed) {
            settingsSheet
        }
        #if DEBUG
        .fullScreenCover(item: $recorderLaunch) { launch in
            RecordingView(launch: launch)
        }
        #endif
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refresh() }
        }
        .onChange(of: showWorkout) { _, isShowing in
            if !isShowing {
                launchMode = .live
                refresh()
            }
        }
        .task { await applyLaunchScreen() }
    }

    private func refresh() {
        balanceMinutes = SharedStore.earnedBalanceMinutes
    }

    @ViewBuilder
    private var settingsSheet: some View {
        #if DEBUG
        // The recorder is full screen, so Settings closes first and the
        // cover opens from `settingsDismissed`.
        SettingsView(onOpenRecorder: { openRecorderAfterSettings = true })
        #else
        SettingsView()
        #endif
    }

    private func settingsDismissed() {
        refresh()
        #if DEBUG
        if openRecorderAfterSettings {
            openRecorderAfterSettings = false
            recorderLaunch = .setup
        }
        #endif
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Text("PressPass")
                .font(Theme.title(.title2))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
        .hiddenSharedBackground()
        #if DEBUG
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                recorderLaunch = .setup
            } label: {
                Image(systemName: "record.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Record data")
        }
        #endif
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: Hero

    private func hero(today: Int) -> some View {
        VStack(spacing: Theme.Space.xs) {
            RepNumeral(value: today, size: 128, color: Theme.textPrimary)
            Text("press-ups today")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(today) press-ups today")
        .padding(.top, Theme.Space.s)
    }

    private func chips(streak: Int) -> some View {
        GlassGroup(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                StatChip(
                    systemImage: "flame.fill",
                    tint: streak > 0 ? Theme.amber : Theme.textTertiary,
                    text: streak == 1 ? "1 day streak" : "\(streak) day streak"
                )
                StatChip(
                    systemImage: "ticket.fill",
                    tint: Theme.volt,
                    text: "\(balanceMinutes) min banked"
                )
            }
        }
    }

    // MARK: Passes

    @ViewBuilder
    private var passes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Your passes")
                .ticketText()
                .padding(.horizontal, Theme.Space.xl)
                .accessibilityAddTraits(.isHeader)

            if history.records.isEmpty {
                Spacer(minLength: 0)
                EmptyPassesView()
                    .padding(.horizontal, Theme.Space.xl)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.m) {
                        ForEach(history.records) { record in
                            PassCard(record: record, style: .compact)
                        }
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.s)
                }
                .scrollIndicators(.hidden)
                .mask(fadeMask)
            }
        }
    }

    /// Softens the cards at the top and bottom edges of the list.
    private var fadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Theme.Space.l)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Theme.Space.l)
        }
    }

    // MARK: Start

    private var startArea: some View {
        PrimaryButton("Start", systemImage: "play.fill") {
            launchMode = .live
            showWorkout = true
        }
        .matchedTransitionSource(id: Self.zoomID, in: zoomNamespace) { source in
            source.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .breathingGlow()
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.l)
        .accessibilityLabel("Start workout")
        .accessibilityHint("Opens the camera to count your press-ups")
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            Theme.ink900
            RadialGradient(
                colors: [Theme.volt.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.12),
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Launch arguments

    private func applyLaunchScreen() async {
        guard !didApplyLaunchScreen else { return }
        didApplyLaunchScreen = true
        #if DEBUG
        // A beat after launch, so the cover opens with its zoom like a real tap.
        try? await Task.sleep(for: .milliseconds(350))
        switch AppEnvironment.current.initialScreen {
        case .workout:
            launchMode = .live
            showWorkout = true
        case .summary:
            if let record = WorkoutView.demoSummaryRecord() {
                launchMode = .demoSummary(record)
                showWorkout = true
            }
        case .settings:
            showSettings = true
        case .recorder:
            recorderLaunch = .setup
        case .recorderRecording:
            recorderLaunch = .recording
        case .recorderLabel:
            recorderLaunch = .label
        case .recorderList:
            recorderLaunch = .list
        case .home, nil:
            break
        }
        #endif
    }
}

// MARK: - Pieces

/// A small glass chip: an icon and a value.
private struct StatChip: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(minHeight: 44)
        .glassSurface(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A ghosted pass, standing in until the first set is done.
private struct EmptyPassesView: View {
    var body: some View {
        ZStack {
            TicketShape(perforation: 0.68)
                .stroke(Theme.textTertiary.opacity(0.5), lineWidth: 1.5)
            PerforationLine(perforation: 0.68)
                .stroke(Theme.textTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
            VStack(spacing: 0) {
                Text("Press pass").ticketText(Theme.textTertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .frame(height: 132 * 0.68)
                Text("Your first pass prints after your first set")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.l)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your first pass prints after your first set")
    }
}

private extension ToolbarContent {
    /// Drops the glass pill iOS 26 puts behind toolbar items, for the wordmark.
    @ToolbarContentBuilder
    func hiddenSharedBackground() -> some ToolbarContent {
        if #available(iOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

private struct BreathingGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.shadow(color: Theme.volt.opacity(0.3), radius: 16, y: 4)
        } else {
            content.phaseAnimator([0.0, 1.0]) { view, phase in
                view.shadow(color: Theme.volt.opacity(0.16 + 0.34 * phase), radius: 10 + 16 * phase, y: 4)
            } animation: { _ in
                .easeInOut(duration: 2.2)
            }
        }
    }
}

extension View {
    /// A slow breathing volt glow. Static under Reduce Motion.
    func breathingGlow() -> some View {
        modifier(BreathingGlow())
    }
}

/// Groups glass views so they share one sampling region on iOS 26 and later.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environmentObject(WorkoutHistoryStore(fileURL: nil, showsDemoRecords: true))
        .preferredColorScheme(.dark)
        .tint(Theme.volt)
}
