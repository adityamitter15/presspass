import SwiftUI
import UIKit

/// The PressPass look: dark only, one accent colour (volt), rounded numerals
/// and a monospaced "ticket" voice for small print.
enum Theme {
    // MARK: Colour

    static let ink900 = Color(hex: 0x08090B)
    static let ink800 = Color(hex: 0x111317)
    static let ink700 = Color(hex: 0x1B1E24)
    static let ink600 = Color(hex: 0x2A2E37)
    static let line = Color.white.opacity(0.08)

    static let textPrimary = Color(hex: 0xF5F7FA)
    static let textSecondary = Color(hex: 0x9AA3B2)
    static let textTertiary = Color(hex: 0x5E6675)

    /// The one accent: counted reps, primary actions, progress.
    static let volt = Color(hex: 0xC8FF2E)
    static let voltDeep = Color(hex: 0x8FBF12)
    /// A rep attempt that was too shallow.
    static let amber = Color(hex: 0xFFB020)
    /// Cannot see the person, errors.
    static let coral = Color(hex: 0xFF5A4F)

    // MARK: Spacing

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let huge: CGFloat = 48
    }

    /// Corner radius of cards and tickets.
    static let cardRadius: CGFloat = 28

    // MARK: Type

    /// The giant numerals. Deliberately a fixed size: they are read from a
    /// metre away and do not follow Dynamic Type.
    static func heroNumeral(size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
    }

    /// Screen and section titles. Scales with Dynamic Type.
    static func title(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .rounded, weight: .bold)
    }

    /// Haptics, kept in one place so views stay declarative.
    @MainActor
    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

extension Color {
    /// An sRGB colour from a 0xRRGGBB value.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Ticket text

/// The small monospaced upper-case voice used on passes and section labels.
private struct TicketTextStyle: ViewModifier {
    var color: Color
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .tracking(1.5)
            .foregroundStyle(color)
    }
}

extension View {
    func ticketText(_ color: Color = Theme.textSecondary) -> some View {
        modifier(TicketTextStyle(color: color))
    }
}

// MARK: - Screen background

extension View {
    /// The ink background every screen sits on, ignoring the safe area.
    func screenBackground() -> some View {
        background(Theme.ink900.ignoresSafeArea())
    }
}
