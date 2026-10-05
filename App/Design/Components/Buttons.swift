import SwiftUI

/// The volt pill: the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.ink900)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, Theme.Space.xl)
            .background(Capsule().fill(isEnabled ? Theme.volt : Theme.ink600))
            .overlay(
                Capsule().fill(.white.opacity(configuration.isPressed ? 0.18 : 0))
            )
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.pop.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// A full-width volt pill, at least 56 points high.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

/// A capsule on glass, for secondary actions.
struct GlassButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(GlassButtonStyle())
    }
}
