import SwiftUI

/// A glass surface: Liquid Glass on iOS 26 and later, a thin material with a
/// hairline stroke before that. For controls and chips floating over the
/// camera or over scrolling content, never whole screens.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint.opacity(0.18)) }
                    }
                }
                .overlay(shape.stroke(Theme.line, lineWidth: 1))
        }
    }

    @available(iOS 26, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.28)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }
}

/// A capsule button on glass, for secondary actions floating over the camera
/// or over content.
struct GlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.xl)
            .frame(minHeight: 48)
            .glassSurface(in: Capsule(), tint: .white, interactive: true)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.pop.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// A round glass icon button, 44 points at least.
struct GlassIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 44, height: 44)
            .glassSurface(in: Circle(), interactive: true)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.pop.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
