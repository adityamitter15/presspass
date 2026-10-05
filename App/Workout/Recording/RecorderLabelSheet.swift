#if DEBUG
import PushupCore
import SwiftUI

/// Stage 3: label the take that was just recorded. A full-height sheet that
/// cannot be swiped away. The count field starts empty and is never filled in
/// from the app's own count, whether or not the count was shown while
/// recording: that count is not available to this view at all.
struct RecorderLabelSheet: View {
    let take: PendingTake
    let isSaving: Bool
    let errorMessage: String?
    let onTagsChange: (RecordedSession.Tags) -> Void
    let onSave: (Int?) -> Void
    let onDiscard: () -> Void

    @State private var text = ""
    @State private var confirmDiscard = false
    @FocusState private var countFocused: Bool

    private var enteredReps: Int? {
        guard let value = Int(text), (0...300).contains(value) else { return nil }
        return value
    }

    private var canSave: Bool {
        !isSaving && (take.kind != .set || enteredReps != nil)
    }

    private var cheat: RecordedSession.Tags.Cheat { take.kind == .set ? take.tags.cheat : .none }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header
                    switch take.kind {
                    case .set: setBody
                    case .negative: confirmBody("Negative take", "Nothing should have counted. The count is saved as 0.")
                    case .pose: confirmBody("Held pose: \(take.poseLabel.title.lowercased())", "There is no count to enter for a held pose.")
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .background(Theme.ink900.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { countFocused = false }
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.volt)
                }
            }
            .confirmationDialog("Discard this take?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard take", role: .destructive) { onDiscard() }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("Nothing is saved and its video is removed.")
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.ink900)
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
        .tint(Theme.volt)
        .task {
            // Open the number pad for a set once the sheet has settled.
            guard take.kind == .set else { return }
            try? await Task.sleep(for: .milliseconds(450))
            countFocused = true
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Label this take")
                .ticketText()
                .accessibilityAddTraits(.isHeader)
            Text("\(take.subject), \(take.kind.title.lowercased()), \(RecorderCopy.clock(take.duration))")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if take.stoppedAutomatically {
                Text("Stopped automatically at the 5 minute limit.")
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
            }
        }
    }

    private var setBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.l) {
                Text("How many valid press-ups?")
                    .font(Theme.title(.title2))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                CountControl(text: $text, style: .large, focus: $countFocused)
                if cheat != .none {
                    RecorderBanner(
                        tone: .caution,
                        text: "\(cheat.loudName) take: \(cheat.countAdvice)."
                    )
                }
            }
            tagsCard
        }
    }

    private func confirmBody(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.title(.title2))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// The tags as recorded, changeable in case they were wrong at Start.
    private var tagsCard: some View {
        RecorderCard(title: "Tags") {
            VStack(spacing: Theme.Space.s) {
                MenuRow(
                    title: "This take is",
                    options: RecordedSession.Tags.Cheat.allCases,
                    selection: binding(\.cheat),
                    label: { $0.title },
                    tint: cheat == .none ? Theme.textPrimary : Theme.amber
                )
                MenuRow(
                    title: "Tempo",
                    options: RecordedSession.Tags.Tempo.choices,
                    selection: binding(\.tempo),
                    label: { $0.title }
                )
            }
            TechniqueRows(tags: tagsBinding)
        }
    }

    /// The whole tag set, for the technique rows, which change three fields
    /// and the legacy variant together.
    private var tagsBinding: Binding<RecordedSession.Tags> {
        Binding(get: { take.tags }, set: { onTagsChange($0) })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RecordedSession.Tags, Value>) -> Binding<Value> {
        Binding(
            get: { take.tags[keyPath: keyPath] },
            set: { newValue in
                var tags = take.tags
                tags[keyPath: keyPath] = newValue
                onTagsChange(tags)
            }
        )
    }

    private var actions: some View {
        VStack(spacing: Theme.Space.s) {
            if let errorMessage {
                RecorderBanner(tone: .error, text: errorMessage)
            }
            PrimaryButton(isSaving ? "Saving" : "Save", systemImage: "checkmark") {
                countFocused = false
                onSave(enteredReps)
            }
            .disabled(!canSave)
            Button(role: .destructive) {
                confirmDiscard = true
            } label: {
                Text("Discard")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.xs)
        .background(
            Theme.ink900
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
#endif
