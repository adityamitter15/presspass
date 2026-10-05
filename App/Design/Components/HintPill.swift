import SwiftUI

/// A short line of guidance on glass, with an icon. The tone says how much it
/// matters: neutral for information, amber for "do this differently", coral
/// for "I cannot see you".
struct HintPill: View {
    enum Tone {
        case neutral, amber, coral

        var color: Color {
            switch self {
            case .neutral: Theme.textPrimary
            case .amber: Theme.amber
            case .coral: Theme.coral
            }
        }

        fileprivate var tint: Color? {
            switch self {
            case .neutral: nil
            case .amber: Theme.amber
            case .coral: Theme.coral
            }
        }
    }

    let systemImage: String
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(minHeight: 44)
        .glassSurface(in: Capsule(), tint: tone.tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

#Preview {
    VStack(spacing: 16) {
        HintPill(systemImage: "figure.stand", text: "Step back so I can see you")
        HintPill(systemImage: "arrow.down", text: "Go lower", tone: .amber)
        HintPill(systemImage: "eye.slash", text: "I can't see your arms", tone: .coral)
    }
    .padding()
    .screenBackground()
}
