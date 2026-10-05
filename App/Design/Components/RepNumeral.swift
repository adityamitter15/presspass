import SwiftUI

/// The giant rep count. Digits roll with a numeric-text transition and the
/// whole numeral gives a short scale pop each time the value goes up.
struct RepNumeral: View {
    let value: Int
    var size: CGFloat = 190
    var color: Color = Theme.textPrimary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let peak = popScale
        return Text("\(value)")
            .font(Theme.heroNumeral(size: size))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText(value: Double(value)))
            .animation(Motion.pop.animation(reduceMotion: reduceMotion), value: value)
            .keyframeAnimator(initialValue: 1.0, trigger: value) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(peak, duration: 0.09)
                    SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(value) press-ups")
    }

    /// No scale pop under Reduce Motion: the digits still change.
    private var popScale: Double { reduceMotion ? 1.0 : 1.1 }
}

#Preview {
    RepNumeral(value: 12).padding().screenBackground()
}
