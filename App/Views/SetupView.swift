import SwiftUI
import FamilyControls

/// Handles Family Controls authorization and the app/category picker used
/// to decide what gets shielded. Pushed from Settings.
struct SetupView: View {
    @State private var authorizationStatusText: String = "Unknown"
    @State private var isPickerPresented = false
    @State private var selection = FamilyActivitySelection()
    @State private var setupErrorMessage: String?

    var body: some View {
        Form {
            Section {
                Text(authorizationStatusText)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.ink700)
                Button("Request authorization") {
                    Task { await requestAuthorization() }
                }
                .buttonStyle(SetupRowButtonStyle())
                .listRowBackground(Theme.ink700)
            } header: {
                Text("Screen Time authorization").ticketText()
            }

            Section {
                Text("\(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories selected")
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.ink700)
                Button("Choose apps") {
                    isPickerPresented = true
                }
                .buttonStyle(SetupRowButtonStyle())
                .listRowBackground(Theme.ink700)
            } header: {
                Text("Apps to protect").ticketText()
            }

            Section {
                Button("Enable protection") {
                    ShieldController.applyShield(for: selection)
                }
                .buttonStyle(SetupRowButtonStyle())
                .listRowBackground(Theme.ink700)
            }

            if let setupErrorMessage {
                Section {
                    Text(setupErrorMessage)
                        .foregroundStyle(Theme.coral)
                        .listRowBackground(Theme.ink700)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Choose apps")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $isPickerPresented, selection: $selection)
        .onChange(of: selection) { newSelection in
            SharedStore.saveSelection(newSelection)
        }
        .onAppear {
            if let saved = SharedStore.loadSelection() {
                selection = saved
            }
            refreshAuthorizationStatus()
        }
    }

    private func refreshAuthorizationStatus() {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .notDetermined:
            authorizationStatusText = "Not requested"
        case .denied:
            authorizationStatusText = "Denied. Enable in Settings"
        case .approved:
            authorizationStatusText = "Approved"
        @unknown default:
            // Covers newer statuses (e.g. approvedWithDataAccess on later
            // OS versions) without hard-coding to a specific SDK.
            authorizationStatusText = "Approved"
        }
    }

    private func requestAuthorization() async {
        setupErrorMessage = nil
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            refreshAuthorizationStatus()
        } catch {
            setupErrorMessage = "Authorization failed: \(error.localizedDescription)"
            refreshAuthorizationStatus()
        }
    }
}

/// A button row: volt text.
private struct SetupRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.volt)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack { SetupView() }
}
