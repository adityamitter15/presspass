import SwiftUI

/// Sound, hands-free finishing, app blocking and, in DEBUG builds, the
/// developer tools.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppSettings.Key.soundMode) private var soundModeRaw = AppSettings.SoundMode.default.rawValue
    @AppStorage(AppSettings.Key.autoFinish) private var autoFinish = true
    #if DEBUG
    @AppStorage(AppSettings.Key.debugOverlay) private var debugOverlay = false
    @State private var debugMessage: String?
    #endif

    @State private var isSessionActive = false
    @State private var balanceMinutes = 0
    @State private var sessionError: String?

    private var soundMode: Binding<AppSettings.SoundMode> {
        Binding(
            get: { AppSettings.SoundMode(rawValue: soundModeRaw) ?? .default },
            set: { soundModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                soundSection
                workoutSection
                blockingSection
                #if DEBUG
                developerSection
                #endif
                aboutSection
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.custom(Theme.Space.xl))
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.volt)
                }
            }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { refresh() }
            }
        }
    }

    private func refresh() {
        isSessionActive = SharedStore.isSessionActive
        balanceMinutes = SharedStore.earnedBalanceMinutes
    }

    // MARK: Sections

    private var soundSection: some View {
        Section {
            SegmentedChoice(title: "Sound", options: AppSettings.SoundMode.allCases, selection: soundMode) { $0.title }
                .listRowInsets(EdgeInsets(top: Theme.Space.xs, leading: 0, bottom: Theme.Space.xs, trailing: 0))
                .listRowBackground(Color.clear)
        } header: {
            sectionHeader("Sound")
        } footer: {
            Text("Ticks are a soft sound for every press-up. Voice also counts them out loud.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var workoutSection: some View {
        Section {
            Toggle(isOn: $autoFinish) {
                Text("Finish automatically when I get up")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.volt)
            .listRowBackground(Theme.ink700)
        } header: {
            sectionHeader("Workout")
        } footer: {
            Text("When off, a set only ends when you tap Finish.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var blockingSection: some View {
        Section {
            NavigationLink {
                SetupView()
            } label: {
                Text("Choose apps to block")
                    .foregroundStyle(Theme.textPrimary)
            }
            .listRowBackground(Theme.ink700)

            HStack {
                Text("Session")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(isSessionActive ? "Active" : "Inactive")
                    .foregroundStyle(isSessionActive ? Theme.volt : Theme.textSecondary)
            }
            .listRowBackground(Theme.ink700)
            .accessibilityElement(children: .combine)

            Button("Start session") { startSession() }
                .buttonStyle(RowButtonStyle())
                .disabled(isSessionActive || balanceMinutes <= 0)
                .listRowBackground(Theme.ink700)

            Button("End session") { endSession() }
                .buttonStyle(RowButtonStyle())
                .disabled(!isSessionActive)
                .listRowBackground(Theme.ink700)

            if let sessionError {
                Text(sessionError)
                    .font(.footnote)
                    .foregroundStyle(Theme.coral)
                    .listRowBackground(Theme.ink700)
            }
        } header: {
            sectionHeader("App blocking")
        } footer: {
            Text("\(balanceMinutes) \(balanceMinutes == 1 ? "minute" : "minutes") banked.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    #if DEBUG
    private var developerSection: some View {
        Section {
            Toggle(isOn: $debugOverlay) {
                Text("Debug overlay")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.volt)
            .listRowBackground(Theme.ink700)

            NavigationLink {
                RecordingView()
            } label: {
                Text("Data collection mode")
                    .foregroundStyle(Theme.textPrimary)
            }
            .listRowBackground(Theme.ink700)

            NavigationLink {
                GateSpikeView()
            } label: {
                Text("Gate spike")
                    .foregroundStyle(Theme.textPrimary)
            }
            .listRowBackground(Theme.ink700)

            Button("Credit 3 test minutes") {
                BalanceStore.credit(minutes: 3)
                do {
                    try MeteringCoordinator.startEarnedSession()
                    debugMessage = "Credited 3 minutes and started a session."
                } catch {
                    debugMessage = "Credited 3 minutes. Session start failed: \(error.localizedDescription)"
                }
                refresh()
            }
            .buttonStyle(RowButtonStyle())
            .listRowBackground(Theme.ink700)

            if let debugMessage {
                Text(debugMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.ink700)
            }
        } header: {
            sectionHeader("Developer")
        }
    }
    #endif

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(Self.versionString)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.ink700)
            .accessibilityElement(children: .combine)
        } header: {
            sectionHeader("About")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).ticketText()
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: App blocking

    private func startSession() {
        sessionError = nil
        do {
            try MeteringCoordinator.startEarnedSession()
            refresh()
        } catch MeteringCoordinator.MeteringError.noBalance {
            sessionError = "Do some press-ups first. You have no earned minutes."
        } catch MeteringCoordinator.MeteringError.noSelectionSaved {
            sessionError = "Pick which apps to protect first."
        } catch {
            sessionError = "Couldn't start the session: \(error.localizedDescription)"
        }
    }

    private func endSession() {
        MeteringCoordinator.stopSession()
        refresh()
    }
}

// MARK: - Controls

/// A button row in a settings list: volt text, grey when disabled.
private struct RowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.volt : Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A pill-shaped segmented control in the app's colours.
private struct SegmentedChoice<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(Motion.pop.animation(reduceMotion: reduceMotion)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.ink900 : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.volt)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xs)
        .background(Capsule().fill(Theme.ink700))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
        .tint(Theme.volt)
}
