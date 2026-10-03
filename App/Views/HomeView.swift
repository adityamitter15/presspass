import SwiftUI

/// Balance dashboard: shows earned minutes, session state, and lets the user
/// start or stop a metered session.
struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var balanceMinutes: Int = 0
    @State private var isSessionActive: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("\(balanceMinutes)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                    Text("earned minutes")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                Text(isSessionActive ? "Session active" : "Session inactive")
                    .font(.subheadline)
                    .foregroundStyle(isSessionActive ? .green : .secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 12) {
                    Button("Start session") {
                        startSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSessionActive || balanceMinutes <= 0)

                    Button("End session") {
                        endSession()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isSessionActive)
                }
                .padding(.horizontal, 40)

                Spacer()
            }
            .padding()
            .navigationTitle("PushupTime")
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        balanceMinutes = SharedStore.earnedBalanceMinutes
        isSessionActive = SharedStore.isSessionActive
    }

    private func startSession() {
        errorMessage = nil
        do {
            try MeteringCoordinator.startEarnedSession()
            refresh()
        } catch MeteringCoordinator.MeteringError.noBalance {
            errorMessage = "Do some pushups first — you have no earned minutes."
        } catch MeteringCoordinator.MeteringError.noSelectionSaved {
            errorMessage = "Pick which apps to protect in Setup first."
        } catch {
            errorMessage = "Couldn't start the session: \(error.localizedDescription)"
        }
    }

    private func endSession() {
        MeteringCoordinator.stopSession()
        refresh()
    }
}

#Preview {
    HomeView()
}
