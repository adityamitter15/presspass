#if DEBUG
import AVFoundation
import PushupCore
import SwiftUI
import UIKit

/// DEBUG-only data-collection mode. Records full pushup sets, negatives
/// (things that must not count) and held poses as raw landmark streams, each
/// with a human-entered ground truth and condition tags, in the versioned
/// schema documented in `docs/data-format.md`. The app's own count is never
/// shown until a take has been saved. Not reachable from Release builds.
struct RecordingView: View {
    @StateObject private var viewModel = RecordingViewModel()

    // Setup values persist across launches so only what changed between
    // takes needs touching.
    @AppStorage("recorder.kind") private var kind: RecordedSession.Kind = .set
    @AppStorage("recorder.subject") private var subject = "S01"
    @AppStorage("recorder.lighting") private var lighting: RecordedSession.Tags.Lighting = .indoorBright
    @AppStorage("recorder.distance") private var distance: RecordedSession.Tags.Distance = .mid
    @AppStorage("recorder.clothing") private var clothing: RecordedSession.Tags.Clothing = .fitted
    @AppStorage("recorder.tempo") private var tempo: RecordedSession.Tags.Tempo = .normal
    @AppStorage("recorder.variant") private var variant: RecordedSession.Tags.Variant = .standard
    @AppStorage("recorder.cheat") private var cheat: RecordedSession.Tags.Cheat = .none
    @AppStorage("recorder.poseLabel") private var poseLabel: PoseLabel = .up
    @AppStorage("recorder.notes") private var notes = ""
    @AppStorage("recorder.saveVideo") private var saveVideo = true

    @State private var pendingDeleteURL: URL?
    @State private var exportFile: ExportFile?

    private static let poseLabels: [PoseLabel] = [.up, .down, .notPushup]

    var body: some View {
        VStack(spacing: 0) {
            cameraPreviewCard

            Form {
                recordSection
                setupSection
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if let warningMessage = viewModel.warningMessage {
                    Section {
                        Text(warningMessage).foregroundStyle(.orange)
                    }
                }
                savedSection
                exportSection
            }
        }
        .navigationTitle("Data collection")
        .onAppear {
            // The phone sits untouched on the floor during a set.
            UIApplication.shared.isIdleTimerDisabled = true
            viewModel.refreshSaved()
            viewModel.startCamera()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            viewModel.stopCamera()
        }
        .sheet(item: Binding(get: { viewModel.pendingTake }, set: { _ in })) { take in
            TrueCountSheet(
                take: take,
                isSaving: viewModel.isSaving,
                errorMessage: viewModel.errorMessage,
                onSave: { viewModel.savePending(trueReps: $0) },
                onDiscard: { viewModel.discardPending() }
            )
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDeleteURL != nil },
                set: { isPresented in
                    if !isPresented { pendingDeleteURL = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let url = pendingDeleteURL {
                    viewModel.delete([url])
                }
                pendingDeleteURL = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteURL = nil
            }
        }
    }

    // MARK: - Camera

    /// Live camera preview + skeleton overlay + a small "body
    /// detected" indicator, shown near the top of the screen so the user
    /// can frame themselves before hitting Start. The camera runs for the
    /// lifetime of this view (started `onAppear`, stopped `onDisappear`),
    /// not just while recording.
    private var cameraPreviewCard: some View {
        ZStack(alignment: .topTrailing) {
            CameraPreviewView(previewLayer: viewModel.previewLayer)
            SkeletonOverlayView(frame: viewModel.latestFrame)
            bodyDetectedBadge
                .padding(8)
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var bodyDetectedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(viewModel.isBodyDetected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.isBodyDetected ? "Body detected" : "Not detected")
                .font(.caption2)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
    }

    // MARK: - Record

    private var canStart: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.pendingTake == nil
            && !viewModel.isFinalizing
    }

    private var recordSection: some View {
        Section {
            if viewModel.isRecording {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Recording")
                    Spacer()
                    Text("\(clockText(viewModel.elapsedSeconds))  \(viewModel.recordedFrameCount) frames")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button {
                    viewModel.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } else {
                if viewModel.isFinalizing {
                    HStack {
                        ProgressView()
                        Text("Finishing video")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    viewModel.start(setup: currentSetup)
                } label: {
                    Label("Start", systemImage: "record.circle")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private var currentSetup: RecordingSetup {
        RecordingSetup(
            kind: kind,
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: RecordedSession.Tags(
                lighting: lighting,
                distance: distance,
                clothing: clothing,
                tempo: tempo,
                variant: variant,
                cheat: cheat
            ),
            poseLabel: poseLabel,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            saveVideo: saveVideo
        )
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section {
            Picker("Kind", selection: $kind) {
                ForEach(RecordedSession.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Subject")
                TextField("S01", text: $subject)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            TagPicker(title: "Lighting", selection: $lighting)
            TagPicker(title: "Distance", selection: $distance)
            TagPicker(title: "Clothing", selection: $clothing)

            if kind == .set {
                TagPicker(title: "Tempo", selection: $tempo)
                TagPicker(title: "Variant", selection: $variant)
                TagPicker(title: "Cheat", selection: $cheat)
            }

            if kind == .pose {
                Picker("Pose", selection: $poseLabel) {
                    ForEach(Self.poseLabels, id: \.self) { label in
                        Text(label.title).tag(label)
                    }
                }
                .pickerStyle(.inline)
            }

            TextField("Notes (optional)", text: $notes)

            Toggle("Save video", isOn: $saveVideo)
                .disabled(!viewModel.isVideoAvailable)
        } header: {
            Text("Setup")
        } footer: {
            Text(statusLine)
        }
        .disabled(viewModel.isRecording)
    }

    /// Motion sensors and video, for the footer under Setup.
    private var statusLine: String {
        let motion = viewModel.isMotionAvailable ? "on" : "unavailable"
        let video = !viewModel.isVideoAvailable ? "unavailable" : (saveVideo ? "on" : "off")
        return "Motion sensors: \(motion). Video: \(video)"
    }

    // MARK: - Saved

    private var savedSection: some View {
        Section {
            if viewModel.saved.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(viewModel.saved) { summary in
                SavedRow(summary: summary) {
                    pendingDeleteURL = summary.url
                }
            }
            .onDelete { offsets in
                let saved = viewModel.saved
                viewModel.delete(offsets.compactMap { saved.indices.contains($0) ? saved[$0].url : nil })
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved sessions")
                Text(totalsLine)
                    .font(.footnote.weight(.regular))
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var totalsLine: String {
        let t = viewModel.totals
        return "\(t.sets) sets, \(t.trueReps) true reps, \(t.negatives) negatives, \(t.poses) held poses"
    }

    private var exportSection: some View {
        Section {
            Button {
                viewModel.exportAll { exportFile = ExportFile(url: $0) }
            } label: {
                HStack {
                    Label("Export all", systemImage: "square.and.arrow.up.on.square")
                    if viewModel.isExporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isExporting || viewModel.saved.isEmpty)
            .sheet(item: $exportFile) { file in
                ShareSheet(url: file.url)
            }
        }
    }

}

private func clockText(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Pending take sheet

/// Asks for the true count after a take. The app's own count is not
/// available here by construction, and the field starts empty.
private struct TrueCountSheet: View {
    let take: PendingTake
    let isSaving: Bool
    let errorMessage: String?
    let onSave: (Int?) -> Void
    let onDiscard: () -> Void

    @State private var text = ""
    @State private var confirmDiscard = false
    @FocusState private var fieldFocused: Bool

    private var enteredReps: Int? {
        guard let value = Int(text), (0...300).contains(value) else { return nil }
        return value
    }

    private var canSave: Bool {
        !isSaving && (take.kind != .set || enteredReps != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(take.kind.title), \(clockText(take.duration)), \(take.frameCount) frames")
                        .foregroundStyle(.secondary)
                    if take.stoppedAutomatically {
                        Text("Stopped automatically at the 5 minute limit.")
                            .foregroundStyle(.secondary)
                    }
                }

                if take.kind == .set {
                    Section("How many valid reps did you do?") {
                        TextField("Number of reps", text: digitsOnly)
                            .keyboardType(.numberPad)
                            .focused($fieldFocused)
                        if !text.isEmpty, enteredReps == nil {
                            Text("Enter a whole number from 0 to 300.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Section {
                        Text(take.kind == .negative
                             ? "Save this as a negative take: no valid reps."
                             : "Save this held pose.")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        onSave(enteredReps)
                    } label: {
                        Text("Save")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    Button("Discard", role: .destructive) {
                        confirmDiscard = true
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle("Save take")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Discard this take?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { onDiscard() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled()
        .onAppear { fieldFocused = take.kind == .set }
    }

    /// Keeps only ASCII digits, so the field cannot hold a sign or a decimal.
    private var digitsOnly: Binding<String> {
        Binding(
            get: { text },
            set: { text = String($0.filter { $0.isASCII && $0.isNumber }.prefix(3)) }
        )
    }
}

// MARK: - Saved row

private struct SavedRow: View {
    let summary: RecordingSummary
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.kind.title).font(.subheadline.bold())
                    Text(summary.subject).font(.subheadline)
                    Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if summary.hasVideo {
                        Image(systemName: "video.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Has video")
                    }
                }
                result
                Text(tagSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ShareLink(item: summary.url) {
                Image(systemName: "square.and.arrow.up")
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var result: some View {
        if let trueReps = summary.trueReps {
            let appReps = summary.liveReps
            let agrees = appReps == trueReps
            // The difference is highlighted whenever the app disagrees.
            HStack(spacing: 4) {
                Text("true \(trueReps) / app \(appReps.map(String.init) ?? "?")")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(agrees ? Color.primary : Color.orange)
                if let appReps, appReps != trueReps {
                    Text(String(format: "%+d", appReps - trueReps))
                        .font(.footnote.bold().monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Text("\(summary.frameCount) frames")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var tagSummary: String {
        let tags = summary.tags
        var parts = [tags.lighting.rawValue, tags.distance.rawValue, tags.clothing.rawValue]
        if tags.tempo != .na { parts.append(tags.tempo.rawValue) }
        if tags.variant != .na { parts.append(tags.variant.rawValue) }
        if tags.cheat != .none { parts.append("cheat: \(tags.cheat.rawValue)") }
        return parts.joined(separator: " / ")
    }
}

// MARK: - Helpers

/// A menu picker over every case of a tag enum.
private struct TagPicker<Value: Hashable & CaseIterable & RawRepresentable>: View
    where Value.RawValue == String, Value.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: Value

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Value.allCases), id: \.self) { value in
                Text(value.rawValue.replacingOccurrences(of: "_", with: " ")).tag(value)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for a file, used for the export archive, which is
/// only known once it has been built.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension RecordedSession.Kind {
    var title: String {
        switch self {
        case .set: return "Set"
        case .negative: return "Negative"
        case .pose: return "Held pose"
        }
    }
}

private extension PoseLabel {
    var title: String {
        switch self {
        case .up: return "Up (top position, arms extended)"
        case .down: return "Down (bottom position, chest low)"
        case .notPushup: return "Not a pushup (standing, sitting, etc.)"
        }
    }
}

#Preview {
    NavigationStack {
        RecordingView()
    }
}
#endif
