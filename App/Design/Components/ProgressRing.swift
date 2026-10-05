import SwiftUI

/// A plain progress ring in volt, for the start hold and the finishing
/// countdown. Not the depth ring: no ripple, no glow states.
struct ProgressRing<Content: View>: View {
    /// 0 to 1.
    let progress: Double
    var diameter: CGFloat
    var lineWidth: CGFloat
    @ViewBuilder var content: () -> Content

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.ink600.opacity(0.7), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(clamped, 0.0001))
                .stroke(
                    AngularGradient(
                        colors: [Theme.voltDeep, Theme.volt],
                        center: .center,
                        startAngle: .zero,
                        endAngle: .degrees(max(clamped, 0.05) * 360)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .opacity(clamped < 0.01 ? 0 : 1)
            content()
        }
        .frame(width: diameter, height: diameter)
    }
}
