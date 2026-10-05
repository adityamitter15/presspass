#if DEBUG
import PushupCore
import SwiftUI

/// Stage 2: the take is running. The same three bands as the workout: the
/// camera fills the screen with the skeleton over the person, the top band
/// holds the REC time and a large Stop button, the middle is left clear and
/// the floor band holds the depth ring. With "Show count while recording" on
/// the ring holds the app's count and the rep sounds play, exactly as in the
/// workout; with it off the ring shows depth alone.
struct RecorderLiveView: View {
    @ObservedObject var viewModel: RecordingViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            cameraLayers
            hud
        }
        .background(Theme.ink900.ignoresSafeArea())
        .sensoryFeedback(.impact(flexibility: .soft), trigger: viewModel.shownReps)
        .confirmationDialog("Discard this take?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard take", role: .destructive) { viewModel.cancelTake() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Nothing is saved and its video is removed.")
        }
    }

    // MARK: Layers

    private var cameraLayers: some View {
        ZStack {
            RecorderCameraLayers(viewModel: viewModel)
                .ignoresSafeArea()
            scrim
        }
        .accessibilityHidden(true)
    }

    /// The workout's scrim: light at the top so the controls read on a white
    /// wall, nothing over the person band, a long ramp to ink at the bottom
    /// so the ring reads on a pale floor. The skeleton sits above it.
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

    // MARK: HUD

    private var hud: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let metrics = WorkoutLayout.Metrics(
                size: CGSize(width: geo.size.width, height: geo.size.height + insets.top + insets.bottom),
                safeTop: insets.top,
                safeBottom: insets.bottom
            )
            ZStack(alignment: .top) {
                ring(metrics)
                    .position(x: metrics.size.width / 2, y: metrics.ringCenterY)
                topBand
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, metrics.safeTop + Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Floor band

    private func ring(_ metrics: WorkoutLayout.Metrics) -> some View {
        let diameter = metrics.ringDiameter
        let showsCount = viewModel.activeCountVisible
        return ZStack {
            Circle()
                .fill(Theme.ink900.opacity(0.55))
                .frame(width: diameter + 48, height: diameter + 48)
                .blur(radius: 16)

            DepthRing(
                depth: viewModel.liveDepth,
                rippleTrigger: viewModel.shownReps,
                isShallow: viewModel.isShallowFlash,
                diameter: diameter,
                lineWidth: diameter * 0.075,
                maxRippleDiameter: metrics.maxRippleDiameter,
                accessibilityLabel: "Depth"
            ) {
                if showsCount {
                    RepNumeral(value: viewModel.shownReps, size: diameter * 0.56)
                } else {
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: diameter * 0.2, weight: .semibold))
                        Text("Blind take")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Blind take, count hidden")
                }
            }
        }
    }

    // MARK: Top band

    private var topBand: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                RecChip(seconds: viewModel.elapsedSeconds, isLive: viewModel.isRecording, reduceMotion: reduceMotion)
                Spacer(minLength: Theme.Space.s)
                if viewModel.isFinalizing {
                    FinishingChip()
                } else {
                    Button {
                        viewModel.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(StopButtonStyle())
                    .accessibilityHint("Ends the take and asks for your count")
                }
            }
            if !viewModel.isFinalizing {
                HStack(alignment: .center) {
                    Text(viewModel.activeTakeLabel)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(viewModel.activeTakeIsUnusual ? Theme.ink900 : Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(viewModel.activeTakeIsUnusual ? Theme.amber : Theme.ink900.opacity(0.55)))
                    Spacer(minLength: Theme.Space.s)
                    Button("Cancel take") { confirmCancel = true }
                        .buttonStyle(CancelChipStyle())
                }
            }
        }
    }
}

// MARK: - Pieces

/// A red dot and the elapsed time, on glass.
private struct RecChip: View {
    let seconds: TimeInterval
    let isLive: Bool
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(Theme.coral)
                .frame(width: 14, height: 14)
                .phaseAnimator(isLive && !reduceMotion ? [1.0, 0.35] : [1.0]) { dot, opacity in
                    dot.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.8)
                }
                .accessibilityHidden(true)
            Text("REC")
                .foregroundStyle(Theme.coral)
            Text(RecorderCopy.clock(seconds))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel("Recording time \(Int(seconds)) seconds")
        }
        .font(.system(.headline, design: .rounded, weight: .bold).monospacedDigit())
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 56)
        .glassSurface(in: Capsule(), tint: Theme.ink900, tintOpacity: 0.55)
    }
}

/// Shown in place of Stop while the video file is completed.
private struct FinishingChip: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().tint(Theme.textPrimary)
            Text("Finishing video")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 56)
        .glassSurface(in: Capsule(), tint: Theme.ink900, tintOpacity: 0.55)
    }
}

/// The large Stop button: 56 points high, glass tinted red.
private struct StopButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.xl)
            .frame(minWidth: 148, minHeight: 56)
            .background(Capsule().fill(Theme.coral.opacity(0.85)))
            .glassSurface(in: Capsule(), tint: Theme.coral, tintOpacity: 0.5, interactive: true)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.pop.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// A small glass button for the rare case of throwing a take away.
private struct CancelChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 44)
            .glassSurface(in: Capsule(), tint: Theme.ink900, tintOpacity: 0.55, interactive: true)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
