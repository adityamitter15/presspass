import PushupCore
import SwiftUI

/// Where things go on the workout screen. With the phone on the floor the
/// person fills only a band of the picture, so the HUD keeps out of it:
///
/// - person band, 28 to 64 percent of the height: camera and skeleton only;
/// - floor band, below that: the ring with the count, the one big element;
/// - top band, above the person: chips, the Finish button and the hint.
enum WorkoutLayout {
    static let personTop: CGFloat = 0.28
    static let personBottom: CGFloat = 0.64

    struct Metrics {
        let size: CGSize
        let safeTop: CGFloat
        let safeBottom: CGFloat

        /// The ring is as large as the floor band allows, within comfortable margins.
        var ringDiameter: CGFloat {
            let floorHeight = size.height - safeBottom - size.height * WorkoutLayout.personBottom
            return max(160, min(260, floorHeight - Theme.Space.xl, size.width - Theme.Space.xxl * 2))
        }

        var ringCenterY: CGFloat {
            let top = size.height * WorkoutLayout.personBottom
            let bottom = size.height - safeBottom
            return (top + bottom) / 2
        }

        /// Never let the counted-rep ripple leave the screen.
        var maxRippleDiameter: CGFloat { size.width - Theme.Space.xl }
    }
}

/// The HUD for the current phase, laid out in the three bands.
struct WorkoutHUD: View {
    @ObservedObject var viewModel: WorkoutViewModel
    var showsDebugOverlay: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The part of the phase that decides what shows, without the countdown value.
    private enum Kind: Equatable { case positioning, active, finishing, finished }

    private var kind: Kind {
        switch viewModel.phase {
        case .positioning: .positioning
        case .active: .active
        case .finishing: .finishing
        case .finished: .finished
        }
    }

    var body: some View {
        // Read the safe area from a proxy that respects it, then lay out over
        // the whole screen: the proxy of a view that ignores the safe area
        // reports zero insets.
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
        .motion(.smooth, value: kind)
    }

    // MARK: Floor band

    private func ring(_ metrics: WorkoutLayout.Metrics) -> some View {
        let diameter = metrics.ringDiameter
        return ZStack {
            // A soft dark disc so the ring and numeral read on a pale floor.
            Circle()
                .fill(Theme.ink900.opacity(0.55))
                .frame(width: diameter + 48, height: diameter + 48)
                .blur(radius: 16)

            DepthRing(
                depth: ringProgress,
                rippleTrigger: viewModel.reps,
                isShallow: viewModel.ringState == .shallow && kind == .active,
                diameter: diameter,
                lineWidth: diameter * 0.075,
                maxRippleDiameter: metrics.maxRippleDiameter,
                accessibilityLabel: ringLabel
            ) {
                ringContent(diameter: diameter)
            }
        }
    }

    /// The same ring in every phase, so going from positioning to counting
    /// happens in place: it fills over the hold, then follows the depth.
    private var ringProgress: Double {
        switch viewModel.phase {
        case .positioning: viewModel.holdProgress
        case .active: viewModel.depth
        case .finishing(let seconds): seconds / max(viewModel.finishingCountdown, 0.001)
        case .finished: 0
        }
    }

    private var ringLabel: String {
        switch kind {
        case .positioning: "Hold position"
        case .active, .finished: "Depth"
        case .finishing: "Finishing in"
        }
    }

    @ViewBuilder
    private func ringContent(diameter: CGFloat) -> some View {
        let numeralSize = diameter * 0.56
        ZStack {
            switch kind {
            case .positioning:
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: diameter * 0.26, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            case .active, .finished:
                ZStack {
                    RepNumeral(value: viewModel.reps, size: numeralSize)
                        .opacity(viewModel.showsGo ? 0 : 1)
                    if viewModel.showsGo {
                        Text("Go")
                            .font(Theme.heroNumeral(size: numeralSize * 0.8))
                            .foregroundStyle(Theme.volt)
                            .shadow(color: Theme.volt.opacity(0.5), radius: 14)
                            .transition(.popIn(reduceMotion: reduceMotion, scale: 0.7))
                            .accessibilityLabel("Go")
                    }
                }
                .motion(.pop, value: viewModel.showsGo)
                .transition(.opacity)
            case .finishing:
                Text("\(wholeSeconds)")
                    .font(Theme.heroNumeral(size: numeralSize))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText(countsDown: true))
                    .motion(.pop, value: wholeSeconds)
                    .shadow(color: .black.opacity(0.35), radius: 10)
                    .transition(.opacity)
                    .accessibilityLabel("\(wholeSeconds) seconds")
            }
        }
    }

    private var wholeSeconds: Int {
        if case .finishing(let seconds) = viewModel.phase { return max(Int(seconds.rounded(.up)), 0) }
        return 0
    }

    // MARK: Top band

    private var topBand: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                leading
                Spacer(minLength: Theme.Space.s)
                button
            }
            secondRow
            #if DEBUG
            if showsDebugOverlay {
                Text(viewModel.debugStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.yellow)
                    .padding(Theme.Space.s)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            #endif
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch kind {
        case .positioning:
            Text("Get into position")
                .font(Theme.title(.title3))
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: .black.opacity(0.55), radius: 6)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
        case .active, .finishing, .finished:
            StatsChip(seconds: viewModel.elapsedSeconds, minutes: viewModel.minutesEarned)
        }
    }

    @ViewBuilder
    private var button: some View {
        switch kind {
        case .positioning: GlassButton("Cancel") { viewModel.requestFinish() }
        case .active: GlassButton("Finish") { viewModel.requestFinish() }
        case .finishing: GlassButton("Finish now") { viewModel.requestFinish() }
        case .finished: EmptyView()
        }
    }

    @ViewBuilder
    private var secondRow: some View {
        switch kind {
        case .positioning:
            VStack(spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    CheckChip(title: "Body in frame", isDone: viewModel.isBodyDetected)
                    CheckChip(title: "Hands on the floor", isDone: viewModel.isPostureValid)
                }
                ZStack {
                    if let hint = viewModel.hint {
                        HintPill(systemImage: hint.systemImage, text: hint.text, tone: hint.tone)
                            .id(hint)
                            .transition(.popIn(reduceMotion: reduceMotion, scale: 0.92))
                    }
                }
                .motion(.pop, value: viewModel.hint)
            }
            .transition(.popIn(reduceMotion: reduceMotion, scale: 0.95))
        case .active:
            ZStack {
                if let hint = viewModel.hint {
                    HintPill(systemImage: hint.systemImage, text: hint.text, tone: hint.tone)
                        .id(hint)
                        .transition(.popIn(reduceMotion: reduceMotion, scale: 0.92))
                }
            }
            .motion(.pop, value: viewModel.hint)
        case .finishing:
            HintPill(systemImage: "arrow.down.circle.fill", text: "Get back down to keep going")
                .transition(.popIn(reduceMotion: reduceMotion, scale: 0.92))
        case .finished:
            EmptyView()
        }
    }
}

// MARK: - Pieces

/// Time and minutes earned, on glass.
private struct StatsChip: View {
    let seconds: Int
    let minutes: Int

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel("Time \(seconds) seconds")
            Text("+\(minutes) min")
                .foregroundStyle(Theme.volt)
                .contentTransition(.numericText(value: Double(minutes)))
                .motion(.pop, value: minutes)
        }
        .font(.system(.headline, design: .rounded, weight: .semibold).monospacedDigit())
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 48)
        .glassSurface(in: Capsule(), tint: Theme.ink900, tintOpacity: 0.55)
    }
}

/// A compact glass chip with a tick that fills in when the check passes.
private struct CheckChip: View {
    let title: String
    let isDone: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(isDone ? Theme.volt : Theme.textSecondary)
                .contentTransition(.symbolEffect(.replace))
                .motion(.pop, value: isDone)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 44)
        .glassSurface(in: Capsule(), tint: Theme.ink900, tintOpacity: 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isDone ? "Done" : "Not yet")
    }
}
