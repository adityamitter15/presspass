import SwiftUI

/// A thick ring that fills as the person goes down, wrapped around the rep
/// numeral. Depth 0 is arms straight, 1 is low enough to count.
///
/// - At full depth the ring brightens with a soft outer glow.
/// - Each counted rep sends out one ripple ring that expands and fades.
/// - A shallow attempt flashes the progress amber.
struct DepthRing<Content: View>: View {
    /// 0 to 1.
    let depth: Double
    /// Changes every time a rep is counted, to fire the ripple.
    let rippleTrigger: Int
    /// True while a shallow attempt is being flagged.
    let isShallow: Bool
    var diameter: CGFloat = 300
    var lineWidth: CGFloat = 22
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(depth, 0), 1) }
    private var isFull: Bool { clamped >= 0.97 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.ink700.opacity(0.6), lineWidth: lineWidth)
                .accessibilityHidden(true)

            progress(colors: [Theme.voltDeep, Theme.volt])
                .opacity(isShallow ? 0 : 1)
                .shadow(color: Theme.volt.opacity(isFull ? 0.65 : 0), radius: isFull ? 22 : 0)

            progress(colors: [Theme.amber.opacity(0.75), Theme.amber])
                .opacity(isShallow ? 1 : 0)
                .shadow(color: Theme.amber.opacity(isShallow ? 0.5 : 0), radius: isShallow ? 16 : 0)

            Circle()
                .stroke(Theme.volt, lineWidth: 3)
                .keyframeAnimator(initialValue: Ripple(), trigger: rippleTrigger) { view, ripple in
                    view
                        .scaleEffect(ripple.scale)
                        .opacity(ripple.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.0, duration: 0.001)
                        CubicKeyframe(1.32, duration: 0.7)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0.85, duration: 0.001)
                        CubicKeyframe(0, duration: 0.7)
                    }
                }
                .opacity(reduceMotion ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // A soft dark disc keeps the numeral readable over a busy image.
            Circle()
                .fill(.black.opacity(0.32))
                .padding(lineWidth * 1.1)
                .blur(radius: 10)
                .accessibilityHidden(true)

            content()
                .frame(maxWidth: diameter - lineWidth * 2 - 24)

            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Depth")
                .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(width: diameter, height: diameter)
        .animation(Motion.smooth.animation(reduceMotion: reduceMotion), value: isFull)
        .animation(Motion.pop.animation(reduceMotion: reduceMotion), value: isShallow)
        .accessibilityElement(children: .contain)
    }

    private func progress(colors: [Color]) -> some View {
        Circle()
            .trim(from: 0, to: max(clamped, 0.0001))
            .stroke(
                AngularGradient(
                    colors: colors,
                    center: .center,
                    startAngle: .zero,
                    endAngle: .degrees(max(clamped, 0.05) * 360)
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .opacity(clamped < 0.01 ? 0 : 1)
            .accessibilityHidden(true)
    }

    private struct Ripple {
        var scale: Double = 1
        var opacity: Double = 0
    }
}

#Preview {
    DepthRing(depth: 0.7, rippleTrigger: 0, isShallow: false) {
        RepNumeral(value: 8)
    }
    .padding()
    .screenBackground()
}
