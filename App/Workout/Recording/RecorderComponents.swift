#if DEBUG
import AVFoundation
import PushupCore
import SwiftUI
import UIKit

// Building blocks of the recorder screens, all in the app's own look: ink
// surfaces, one volt accent, amber for anything that is not an ordinary take.

// MARK: - Card

/// A titled card on the ink background.
struct RecorderCard<Content: View>: View {
    let title: String
    var tint: Color?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title)
                .ticketText(tint ?? Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.ink700)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(tint?.opacity(0.7) ?? Theme.line, lineWidth: tint == nil ? 1 : 1.5)
        )
    }
}

/// A small caption above a group of chips.
struct RecorderFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Chips

/// Wraps its children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = Theme.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A large, easy-to-hit option: filled when selected.
struct OptionChip: View {
    let title: String
    let isSelected: Bool
    var tint: Color = Theme.volt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.ink900 : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.l)
                .frame(minHeight: 48)
                .background(Capsule().fill(isSelected ? tint : Theme.ink600))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One selection out of a few, as a wrapping set of chips.
struct ChipFlow<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var tint: (Value) -> Color = { _ in Theme.volt }

    var body: some View {
        FlowLayout {
            ForEach(options, id: \.self) { option in
                OptionChip(title: title(option), isSelected: option == selection, tint: tint(option)) {
                    selection = option
                }
            }
        }
    }
}

/// A pill-shaped segmented control, 48 points high.
struct RecorderSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(Motion.pop.animation(reduceMotion: reduceMotion)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.ink900 : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.volt).matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xs)
        .background(Capsule().fill(Theme.ink800))
    }
}

/// A compact picker: the title and the current value, opening a menu.
struct MenuRow<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var tint: Color = Theme.textPrimary

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Text(title)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: Theme.Space.s)
                Text(label(selection))
                    .foregroundStyle(tint)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .font(.system(.body, design: .rounded, weight: .semibold))
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.ink600))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
    }
}

// MARK: - Buttons and fields

/// A round button that steps a value, at least 56 points across.
struct StepButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 56
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(isDisabled ? Theme.textTertiary : Theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.ink600))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }
}

/// A full-width secondary action on a filled capsule.
struct RecorderSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(Theme.ink600))
            .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.1 : 0)))
            .contentShape(Capsule())
    }
}

/// Text on an ink field, as used for the subject and notes.
struct RecorderFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.volt)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.ink600))
    }
}

extension View {
    func recorderField() -> some View { modifier(RecorderFieldStyle()) }
}

/// A toggle row with a short explanation underneath.
struct RecorderToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.volt)
        .disabled(!isEnabled)
        .frame(minHeight: 52)
    }
}

// MARK: - Banner

/// A full-width message with an icon. Amber for care, coral for failures,
/// volt for good news.
struct RecorderBanner: View {
    enum Tone { case info, caution, error, success

        var color: Color {
            switch self {
            case .info: Theme.textSecondary
            case .caution: Theme.amber
            case .error: Theme.coral
            case .success: Theme.volt
            }
        }

        var systemImage: String {
            switch self {
            case .info: "info.circle.fill"
            case .caution: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .success: "checkmark.circle.fill"
            }
        }
    }

    let tone: Tone
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: tone.systemImage)
                .font(.headline)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tone == .info ? Theme.ink700 : tone.color.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tone == .info ? Theme.line : tone.color.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// A small pill used on list rows.
struct TagPill: View {
    let text: String
    var color: Color = Theme.textSecondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(filled ? Theme.ink900 : color)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.s + 2)
            .padding(.vertical, 4)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
    }
}

// MARK: - Count control

/// A whole number from 0 to 300 held as text, with big minus and plus buttons
/// and (large style) a number pad field. The text is empty until the person
/// enters something: it is never filled in for them.
struct CountControl: View {
    enum Style { case large, compact }

    @Binding var text: String
    var style: Style = .large
    var focus: FocusState<Bool>.Binding

    private var value: Int? { Int(text) }
    private var numeralSize: CGFloat { style == .large ? 120 : 52 }
    private var buttonSize: CGFloat { style == .large ? 68 : 52 }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.l) {
                StepButton(
                    systemImage: "minus", label: "One fewer", size: buttonSize,
                    isDisabled: (value ?? 0) <= 0
                ) { set((value ?? 1) - 1) }
                Text(text.isEmpty ? "?" : text)
                    .font(Theme.heroNumeral(size: numeralSize))
                    .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focus.wrappedValue = true }
                    .accessibilityLabel(text.isEmpty ? "No count entered" : "\(text) press-ups")
                StepButton(
                    systemImage: "plus", label: "One more", size: buttonSize,
                    isDisabled: (value ?? 0) >= 300
                ) { set((value ?? 0) + 1) }
            }
            if style == .large {
                TextField("", text: digitsOnly, prompt: Text("Or type the number").foregroundStyle(Theme.textSecondary))
                    .keyboardType(.numberPad)
                    .focused(focus)
                    .multilineTextAlignment(.center)
                    .recorderField()
            }
            if !text.isEmpty, value == nil || (value ?? 0) > 300 {
                Text("Enter a whole number from 0 to 300.")
                    .font(.footnote)
                    .foregroundStyle(Theme.coral)
            }
        }
    }

    private func set(_ number: Int) {
        text = String(min(max(number, 0), 300))
    }

    /// Keeps only ASCII digits, so the field cannot hold a sign or a decimal.
    private var digitsOnly: Binding<String> {
        Binding(
            get: { text },
            set: { text = String($0.filter { $0.isASCII && $0.isNumber }.prefix(3)) }
        )
    }
}

// MARK: - Camera pieces

/// The camera preview with the skeleton over it and, in the Simulator, the
/// `-demoBackdrop` still in place of the live image.
struct RecorderCameraLayers: View {
    @ObservedObject var viewModel: RecordingViewModel

    var body: some View {
        ZStack {
            Color.black
            CameraPreviewView(previewLayer: viewModel.previewLayer)
            if viewModel.previewLayer == nil, let image = AppEnvironment.demoBackdropImage {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            SkeletonOverlayView(frame: viewModel.latestFrame)
        }
    }
}

// MARK: - Sharing

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for a file, used for the export archive, which is
/// only known once it has been built.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
