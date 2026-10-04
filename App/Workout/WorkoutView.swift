import PushupCore
import SwiftUI

/// The pushup-counting workout module: camera preview + skeleton overlay,
/// live rep count, and the earn-minutes flow (1 rep = 1 minute).
struct WorkoutView: View {
    @StateObject private var viewModel = WorkoutViewModel()
    @State private var showSummary = false
    @State private var summaryReps = 0
    @State private var sessionStartError: String?

    #if DEBUG
    @State private var debugMessage: String?
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.isRunning {
                    CameraPreviewView(previewLayer: viewModel.previewLayer)
                        .ignoresSafeArea()
                    SkeletonOverlayView(frame: viewModel.latestFrame)
                        .ignoresSafeArea()

                    if !viewModel.isBodyDetected {
                        placementHint
                    }
                } else {
                    idleBackground
                }

                VStack {
                    if viewModel.isRunning {
                        statusBar
                        #if DEBUG
                        debugHUD
                        #endif
                        Spacer()
                        repCounterCard
                        finishButton
                    } else {
                        Spacer()
                        startCard
                        Spacer()
                    }
                }
                .padding()
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                if viewModel.isRunning {
                    viewModel.stop()
                }
            }
            .sheet(isPresented: $showSummary) {
                summarySheet
            }
        }
    }

    // MARK: - Idle state

    private var idleBackground: some View {
        Color(.systemBackground)
    }

    private var startCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Ready to earn minutes")
                .font(.title2.bold())
            Text("Prop your phone on the floor just in front of you, screen facing you, then get into pushup position facing it. 1 pushup = 1 minute.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let sessionStartError {
                Text(sessionStartError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if let cameraErrorMessage = viewModel.cameraErrorMessage {
                Text(cameraErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("Start workout") {
                viewModel.start()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            #if DEBUG
            debugControls
            #endif
        }
        .padding()
    }

    // MARK: - Running state

    private var placementHint: some View {
        VStack {
            Spacer()
            Text("Prop phone on the floor in front of you, facing you")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
    }

    private var statusBar: some View {
        HStack {
            Text(stateLabel)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
            Spacer()
            if viewModel.rejectedReps > 0 {
                Text("\(viewModel.rejectedReps) rejected")
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    private var stateLabel: String {
        if !viewModel.isBodyDetected {
            return "Not detected"
        }
        switch viewModel.currentLabel {
        case .up: return "Up"
        case .down: return "Down"
        case .notPushup: return "Not in position"
        }
    }

    private var repCounterCard: some View {
        VStack(spacing: 4) {
            Text("\(viewModel.reps)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 4)
            Text("\(viewModel.reps) minute\(viewModel.reps == 1 ? "" : "s") earned")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 2)
        }
        .padding()
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
    }

    private var finishButton: some View {
        Button("Finish") {
            finishWorkout()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.top, 12)
    }

    private func finishWorkout() {
        summaryReps = viewModel.reps
        viewModel.stop()
        SharedStore.credit(minutes: summaryReps)
        showSummary = true
    }

    // MARK: - Summary sheet

    private var summarySheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("\(summaryReps) pushup\(summaryReps == 1 ? "" : "s")")
                .font(.largeTitle.bold())
            Text("\(summaryReps) minute\(summaryReps == 1 ? "" : "s") credited to your balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Start using your minutes") {
                do {
                    try MeteringCoordinator.startEarnedSession()
                } catch {
                    // The summary sheet doesn't have room for a full error
                    // flow; Home shows session state and lets the user
                    // retry from there if this fails.
                }
                showSummary = false
            }
            .buttonStyle(.borderedProminent)

            Button("Done") {
                showSummary = false
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .presentationDetents([.medium])
    }

    // MARK: - DEBUG-only controls

    #if DEBUG
    private var debugHUD: some View {
        Text(viewModel.debugStatus)
            .font(.caption2.monospaced())
            .foregroundStyle(.yellow)
            .padding(6)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    #if DEBUG
    private var debugControls: some View {
        VStack(spacing: 8) {
            Divider().padding(.vertical, 4)

            Button("Credit 3 test minutes") {
                BalanceStore.credit(minutes: 3)
                do {
                    try MeteringCoordinator.startEarnedSession()
                    debugMessage = "Credited 3 minutes and started a session."
                } catch {
                    debugMessage = "Credited 3 minutes. Session start failed: \(error.localizedDescription)"
                }
            }
            .buttonStyle(.bordered)

            NavigationLink("Data collection mode") {
                RecordingView()
            }
            .font(.footnote)

            NavigationLink("Gate spike") {
                GateSpikeView()
            }
            .font(.footnote)

            if let debugMessage {
                Text(debugMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif
}

#Preview {
    WorkoutView()
}
