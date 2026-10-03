import SwiftUI
import FamilyControls

/// Handles Family Controls authorization and the app/category picker used
/// to decide what gets shielded.
struct SetupView: View {
    @State private var authorizationStatusText: String = "Unknown"
    @State private var isPickerPresented = false
    @State private var selection = FamilyActivitySelection()
    @State private var setupErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Screen Time authorization") {
                    Text(authorizationStatusText)
                        .foregroundStyle(.secondary)
                    Button("Request authorization") {
                        Task { await requestAuthorization() }
                    }
                }

                Section("Apps to protect") {
                    Text("\(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories selected")
                        .foregroundStyle(.secondary)
                    Button("Choose apps") {
                        isPickerPresented = true
                    }
                }

                Section {
                    Button("Enable protection") {
                        ShieldController.applyShield(for: selection)
                    }
                }

                if let setupErrorMessage {
                    Section {
                        Text(setupErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Setup")
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
    }

    private func refreshAuthorizationStatus() {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .notDetermined:
            authorizationStatusText = "Not requested"
        case .denied:
            authorizationStatusText = "Denied — enable in Settings"
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

#Preview {
    SetupView()
}
