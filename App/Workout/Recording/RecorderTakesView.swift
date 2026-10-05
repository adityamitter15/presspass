#if DEBUG
import PushupCore
import SwiftUI

/// Stage 4: the saved takes, newest first. Tap a row to correct its labels;
/// share or delete a take from its row; export everything at the bottom.
struct RecorderTakesView: View {
    @ObservedObject var viewModel: RecordingViewModel
    var opensEditOnAppear = false

    @State private var pendingDelete: RecordingSummary?
    @State private var editing: RecordingSummary?
    @State private var exportFile: ExportFile?
    @State private var didOpenEdit = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.m) {
                totals
                if viewModel.saved.isEmpty {
                    Text("No takes saved yet.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.huge)
                }
                if let message = viewModel.errorMessage {
                    RecorderBanner(tone: .error, text: message)
                }
                ForEach(viewModel.saved) { summary in
                    TakeRow(
                        summary: summary,
                        onEdit: { editing = summary },
                        onDelete: { pendingDelete = summary }
                    )
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { exportBar }
        .background(Theme.ink900.ignoresSafeArea())
        .navigationTitle("Saved takes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.ink900, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            viewModel.refreshSaved()
        }
        .task(id: viewModel.saved.first?.id) {
            guard opensEditOnAppear, !didOpenEdit, let first = viewModel.saved.first else { return }
            didOpenEdit = true
            try? await Task.sleep(for: .milliseconds(400))
            editing = first
        }
        .sheet(item: $editing) { summary in
            RecorderEditView(viewModel: viewModel, summary: summary)
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(url: file.url)
        }
        .confirmationDialog(
            "Delete this take?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { summary in
            Button("Delete take and video", role: .destructive) {
                viewModel.delete([summary.url])
                pendingDelete = nil
            }
            Button("Keep it", role: .cancel) { pendingDelete = nil }
        } message: { summary in
            Text("\(summary.subject), \(summary.kind.title.lowercased()). This cannot be undone.")
        }
    }

    private var totals: some View {
        let t = viewModel.totals
        return HStack(spacing: Theme.Space.s) {
            stat("\(t.people)", t.people == 1 ? "person" : "people")
            stat("\(t.sets)", t.sets == 1 ? "set" : "sets")
            stat("\(t.trueReps)", "true reps")
            stat("\(t.negatives)", t.negatives == 1 ? "negative" : "negatives")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .ticketText(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.ink700))
        .accessibilityElement(children: .combine)
    }

    private var exportBar: some View {
        Button {
            viewModel.exportAll { exportFile = ExportFile(url: $0) }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Label("Export all", systemImage: "square.and.arrow.up.on.square")
                if viewModel.isExporting { ProgressView().tint(Theme.textPrimary) }
            }
        }
        .buttonStyle(RecorderSecondaryButtonStyle())
        .disabled(viewModel.isExporting || viewModel.saved.isEmpty)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
        .background(
            Theme.ink900
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Row

private struct TakeRow: View {
    let summary: RecordingSummary
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        Text(summary.subject)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if summary.hasVideo {
                            Image(systemName: "video.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityLabel("Has video")
                        }
                        if summary.countVisible == false {
                            Image(systemName: "eye.slash.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityLabel("Blind take, count was hidden")
                        }
                        if summary.editedAt != nil {
                            Image(systemName: "pencil")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityLabel("Edited")
                        }
                        Spacer(minLength: Theme.Space.xs)
                        Text(summary.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    HStack(spacing: Theme.Space.xs) {
                        TagPill(text: summary.kind.title, color: Theme.textPrimary)
                        if summary.kind == .set, summary.tags.variant != .na {
                            TagPill(text: summary.tags.variant.title)
                        }
                        if summary.kind == .set, summary.tags.cheat != .none {
                            TagPill(text: summary.tags.cheat.title, color: Theme.amber, filled: true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    result
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit this take")

            VStack(spacing: 0) {
                ShareLink(item: summary.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share take")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.coral)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete take")
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.ink700))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private var result: some View {
        if let trueReps = summary.trueReps {
            let app = summary.liveReps
            let differs = app != nil && app != trueReps
            HStack(spacing: Theme.Space.s) {
                Text("you \(trueReps) / app \(app.map(String.init) ?? "?")")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(differs ? Theme.amber : Theme.textSecondary)
                if let app, differs {
                    TagPill(text: String(format: "%+d", app - trueReps), color: Theme.amber, filled: true)
                }
            }
        } else if let label = summary.poseLabel {
            Text("held: \(label.title.lowercased())")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Edit

/// Edit take: correct the label fields of a saved take. The kind, frames,
/// motion, video and the app's own count cannot be changed here.
struct RecorderEditView: View {
    @ObservedObject var viewModel: RecordingViewModel
    let summary: RecordingSummary

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var subject: String
    @State private var tags: RecordedSession.Tags
    @State private var notes: String
    @State private var poseLabel: PoseLabel
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var countFocused: Bool
    @FocusState private var textFocused: Bool

    init(viewModel: RecordingViewModel, summary: RecordingSummary) {
        self.viewModel = viewModel
        self.summary = summary
        _text = State(initialValue: summary.trueReps.map(String.init) ?? "")
        _subject = State(initialValue: summary.subject)
        _tags = State(initialValue: summary.tags)
        _notes = State(initialValue: summary.notes)
        _poseLabel = State(initialValue: summary.poseLabel ?? .up)
    }

    private var isSet: Bool { summary.kind == .set }
    private var enteredReps: Int? {
        guard let value = Int(text), (0...300).contains(value) else { return nil }
        return value
    }
    private var canSave: Bool {
        !isSaving && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!isSet || enteredReps != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Only the labels change. The frames, video and the app's own count stay as recorded.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)

                    if isSet {
                        RecorderCard(title: "True count") {
                            CountControl(text: $text, style: .compact, focus: $countFocused)
                        }
                    }

                    RecorderCard(title: "Subject") {
                        TextField("S01", text: $subject)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($textFocused)
                            .recorderField()
                    }

                    RecorderCard(title: "Take") {
                        if isSet {
                            VStack(spacing: Theme.Space.s) {
                                MenuRow(
                                    title: "This take is",
                                    options: RecordedSession.Tags.Cheat.allCases,
                                    selection: $tags.cheat,
                                    label: { $0.title },
                                    tint: tags.cheat == .none ? Theme.textPrimary : Theme.amber
                                )
                                MenuRow(title: "Variant", options: RecordedSession.Tags.Variant.choices, selection: $tags.variant) { $0.title }
                                MenuRow(title: "Tempo", options: RecordedSession.Tags.Tempo.choices, selection: $tags.tempo) { $0.title }
                            }
                        } else if summary.kind == .pose {
                            MenuRow(title: "Pose", options: PoseLabel.choices, selection: $poseLabel) { $0.title }
                        } else {
                            Text("A negative take is always saved with a count of 0.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    RecorderCard(title: "Room") {
                        VStack(spacing: Theme.Space.s) {
                            MenuRow(title: "Lighting", options: RecordedSession.Tags.Lighting.allCases, selection: $tags.lighting) { $0.title }
                            MenuRow(title: "Distance", options: RecordedSession.Tags.Distance.allCases, selection: $tags.distance) { $0.title }
                            MenuRow(title: "Clothing", options: RecordedSession.Tags.Clothing.allCases, selection: $tags.clothing) { $0.title }
                        }
                        TextField("Notes", text: $notes)
                            .submitLabel(.done)
                            .focused($textFocused)
                            .recorderField()
                    }

                    if let errorMessage {
                        RecorderBanner(tone: .error, text: errorMessage)
                    }
                }
                .padding(Theme.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.ink900.ignoresSafeArea())
            .navigationTitle("Edit take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink900, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(canSave ? Theme.volt : Theme.textTertiary)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        countFocused = false
                        textFocused = false
                    }
                    .foregroundStyle(Theme.volt)
                }
            }
        }
        .presentationBackground(Theme.ink900)
        .interactiveDismissDisabled(isSaving)
        .preferredColorScheme(.dark)
        .tint(Theme.volt)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let edit = RecordingViewModel.LabelEdit(
            trueReps: isSet ? enteredReps : (summary.kind == .negative ? 0 : nil),
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: tags,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            poseLabel: summary.kind == .pose ? poseLabel : summary.poseLabel
        )
        viewModel.updateLabels(of: summary.url, edit) { failure in
            isSaving = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }
}
#endif
