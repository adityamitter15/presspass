import SwiftUI
import UIKit

/// The three springs the app moves with. Every animation goes through here so
/// Reduce Motion is honoured in one place: with it on, movement becomes a
/// short cross-fade.
enum Motion {
    /// Quick and lively: counts, chips, small controls.
    case pop
    /// Calm and settled: layout and state changes.
    case smooth
    /// The pass "printing" into place.
    case print

    var animation: Animation {
        switch self {
        case .pop: .spring(duration: 0.32, bounce: 0.38)
        case .smooth: .spring(duration: 0.5, bounce: 0.12)
        case .print: .spring(duration: 0.7, bounce: 0.22)
        }
    }

    /// The animation to use given the Reduce Motion setting.
    func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : animation
    }
}

/// `withAnimation` for state changes made outside a view body.
@discardableResult
func withMotion<Result>(_ motion: Motion, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(motion.animation(reduceMotion: UIAccessibility.isReduceMotionEnabled), body)
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let motion: Motion
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` with a `Motion` preset that respects Reduce Motion.
    func motion<Value: Equatable>(_ motion: Motion, value: Value) -> some View {
        modifier(MotionModifier(motion: motion, value: value))
    }
}

extension AnyTransition {
    /// A scale-and-fade, or a plain fade when Reduce Motion is on.
    static func popIn(reduceMotion: Bool, scale: CGFloat = 0.9) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale).combined(with: .opacity)
    }
}
