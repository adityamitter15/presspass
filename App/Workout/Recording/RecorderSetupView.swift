#if DEBUG
import PushupCore
import SwiftUI

/// Stage 1: everything chosen before a take, on one scrolling screen with the
/// Start button fixed at the bottom. Values persist between takes, with one
/// exception: "This take is" goes back to real press-ups after every take.
struct RecorderSetupView: View {
    @ObservedObject var viewModel: RecordingViewModel
    let onClose: () -> Void
    let onOpenTakes: () -> Void

    @AppStorage(RecorderPrefs.kind) private var kind: RecordedSession.Kind = .set
    @AppStorage(RecorderPrefs.subject) private var subject = "S01"
    @AppStorage(RecorderPrefs.lighting) private var lighting: RecordedSession.Tags.Lighting = .indoorBright
    @AppStorage(RecorderPrefs.distance) private var distance: RecordedSession.Tags.Distance = .mid
    @AppStorage(RecorderPrefs.clothing) private var clothing: RecordedSession.Tags.Clothing = .fitted
    @AppStorage(RecorderPrefs.tempo) private var tempo: RecordedSession.Tags.Tempo = .normal
    @AppStorage(RecorderPrefs.hands) private var hands: RecordedSession.Tags.Hands = .palms
    @AppStorage(RecorderPrefs.support) private var support: RecordedSession.Tags.Support = .toes
    @AppStorage(RecorderPrefs.width) private var width: RecordedSession.Tags.Width = .normal
    @AppStorage(RecorderPrefs.cheat) private var cheat: RecordedSession.Tags.Cheat = .none
    @AppStorage(RecorderPrefs.poseLabel) private var poseLabel: PoseLabel = .up
    @AppStorage(RecorderPrefs.notes) private var notes = ""
    @AppStorage(RecorderPrefs.saveVideo) private var saveVideo = true
    @AppStorage(RecorderPrefs.countVisible) private var countVisible = true

    private enum Field: Hashable { case subject, notes }
    @FocusState private var focus: Field?

    private var trimmedSubject: String { subject.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canStart: Bool {
        !trimmedSubject.isEmpty && viewModel.pendingTake == nil && !viewModel.isFinalizing
    }

    /// A cheat only applies to a set; a stale value under another kind is ignored.
    private var effectiveCheat: RecordedSession.Tags.Cheat { kind == .set ? cheat : .none }
    private var isUnusual: Bool { RecorderCopy.isUnusual(kind: kind, cheat: effectiveCheat) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: Theme.Space.l) {
                    cameraCard
                    personCard
                    takeCard.id("take")
                    roomCard
                    optionsCard
                    takesRow
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                // Screenshots only: show the lower half of the screen.
                guard let target = AppEnvironment.current.recorderScroll else { return }
                try? await Task.sleep(for: .milliseconds(900))
                scroller.scrollTo(target, anchor: target == "end" ? .bottom : .top)
            }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .background(Theme.ink900.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.volt)
            }
        }
        .task(id: viewModel.savedNotice?.id) {
            guard viewModel.savedNotice != nil else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { viewModel.dismissNotice() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Record data")
                .font(Theme.title(.title2))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(GlassIconButtonStyle())
            .accessibilityLabel("Close recorder")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    // MARK: Camera

    private var cameraCard: some View {
        ZStack(alignment: .topTrailing) {
            RecorderCameraLayers(viewModel: viewModel)
            bodyBadge.padding(Theme.Space.m)
        }
        .frame(height: 280)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera preview")
        .accessibilityValue(viewModel.isBodyDetected ? "Body detected" : "Not detected")
    }

    private var bodyBadge: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(viewModel.isBodyDetected ? Theme.volt : Theme.coral)
                .frame(width: 10, height: 10)
            Text(viewModel.isBodyDetected ? "Body detected" : "Not detected")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 36)
        .glassSurface(in: Capsule(), tint: Theme.ink900, tintOpacity: 0.55)
    }

    // MARK: Person

    private var personCard: some View {
        RecorderCard(title: "Person") {
            VStack(spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    StepButton(systemImage: "minus", label: "Previous subject") {
                        subject = RecordedSession.previousSubject(before: subject)
                    }
                    TextField("S01", text: $subject)
                        .font(Theme.heroNumeral(size: 44))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.volt)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focus, equals: .subject)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.ink800))
                        .accessibilityLabel("Subject")
                    StepButton(systemImage: "plus", label: "Next subject") {
                        subject = RecordedSession.nextSubject(after: subject)
                    }
                }
                Text("Tap the label to type your own")
                    .ticketText(Theme.textTertiary)
                Button {
                    subject = RecordedSession.nextSubject(after: subject)
                    focus = nil
                } label: {
                    Label("Next person", systemImage: "person.fill.badge.plus")
                }
                .buttonStyle(RecorderSecondaryButtonStyle())
            }
        }
    }

    // MARK: Take

    private var takeCard: some View {
        RecorderCard(title: "Take") {
            RecorderSegmented(options: RecordedSession.Kind.allCases, selection: $kind) { $0.title }

            switch kind {
            case .set:
                TechniqueRows(hands: $hands, support: $support, width: $width)
                RecorderFieldLabel("Tempo")
                ChipFlow(options: RecordedSession.Tags.Tempo.choices, selection: $tempo) { $0.title }
                cheatBox
            case .pose:
                VStack(spacing: Theme.Space.s) {
                    ForEach(PoseLabel.choices, id: \.self) { label in
                        poseRow(label)
                    }
                }
            case .negative:
                Text("Nothing should count in this take: plank, stretching, walking past, sitting. The count is saved as 0. Say what you did in the notes.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .workout:
                EmptyView()
            }
        }
        .disabled(viewModel.isRecording)
    }

    /// "This take is", set apart so a cheat cannot be chosen by accident and
    /// stands out when it is.
    private var cheatBox: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("This take is")
                .ticketText(cheat == .none ? Theme.textSecondary : Theme.amber)
            ChipFlow(
                options: RecordedSession.Tags.Cheat.allCases,
                selection: $cheat,
                title: { $0.title },
                tint: { $0 == .none ? Theme.volt : Theme.amber }
            )
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cheat == .none ? Theme.ink800 : Theme.amber.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cheat == .none ? Theme.line : Theme.amber.opacity(0.7), lineWidth: 1)
        )
    }

    private func poseRow(_ label: PoseLabel) -> some View {
        let isSelected = label == poseLabel
        return Button {
            poseLabel = label
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.title)
                    .font(.system(.body, design: .rounded, weight: .bold))
                Text(label.detail)
                    .font(.footnote)
                    .foregroundStyle(isSelected ? Theme.ink900.opacity(0.75) : Theme.textSecondary)
            }
            .foregroundStyle(isSelected ? Theme.ink900 : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isSelected ? Theme.volt : Theme.ink600))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Room

    private var roomCard: some View {
        RecorderCard(title: "Room") {
            RecorderFieldLabel("Lighting")
            ChipFlow(options: RecordedSession.Tags.Lighting.allCases, selection: $lighting) { $0.title }
            RecorderFieldLabel("Distance")
            ChipFlow(options: RecordedSession.Tags.Distance.allCases, selection: $distance) { $0.title }
            Text("Phone to hands: near 0.6 to 0.9 m, mid 1.0 to 1.5 m, far 1.8 to 2.5 m.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
            RecorderFieldLabel("Clothing")
            ChipFlow(options: RecordedSession.Tags.Clothing.allCases, selection: $clothing) { $0.title }
            RecorderFieldLabel("Notes")
            TextField("Floor type, anything odd", text: $notes)
                .submitLabel(.done)
                .focused($focus, equals: .notes)
                .recorderField()
        }
        .disabled(viewModel.isRecording)
    }

    // MARK: Options

    private var optionsCard: some View {
        RecorderCard(title: "Options") {
            RecorderToggleRow(
                title: "Save video",
                detail: viewModel.isVideoAvailable
                    ? "Keeps the camera video next to the take. Switch off for anyone who did not agree."
                    : "Not available on this device.",
                isOn: $saveVideo,
                isEnabled: viewModel.isVideoAvailable
            )
            Divider().overlay(Theme.line)
            RecorderToggleRow(
                title: "Show count while recording",
                detail: "Off records a blind take: no number, no ripple and no rep sounds.",
                isOn: $countVisible
            )
        }
    }

    // MARK: Saved takes

    private var takesRow: some View {
        Button(action: onOpenTakes) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Saved takes (\(viewModel.saved.count))")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(totalsLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.ink700))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var totalsLine: String {
        let t = viewModel.totals
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        return [
            count(t.people, "person", "people"),
            count(t.sets, "set", "sets"),
            count(t.trueReps, "true rep", "true reps"),
            count(t.negatives, "negative", "negatives"),
        ].joined(separator: ", ")
    }

    private var statusLine: String {
        let motion = viewModel.isMotionAvailable ? "on" : "unavailable"
        let video = !viewModel.isVideoAvailable ? "unavailable" : (saveVideo ? "on" : "off")
        return "Motion sensors: \(motion). Video: \(video)."
    }

    // MARK: Start

    private var startTitle: String {
        guard !trimmedSubject.isEmpty else { return "Enter a subject to start" }
        return RecorderCopy.startTitle(
            subject: trimmedSubject, kind: kind, tags: currentSetup.tags, cheat: effectiveCheat, poseLabel: poseLabel
        )
    }

    private var startBar: some View {
        VStack(spacing: Theme.Space.s) {
            if let notice = viewModel.savedNotice {
                RecorderBanner(tone: .success, text: notice.text) { viewModel.dismissNotice() }
            }
            if let message = viewModel.errorMessage {
                RecorderBanner(tone: .error, text: message)
            }
            if let warning = viewModel.warningMessage {
                RecorderBanner(tone: .caution, text: warning)
            }
            if let banner = RecorderCopy.banner(kind: kind, cheat: effectiveCheat) {
                RecorderBanner(tone: .caution, text: banner)
            }
            if viewModel.isFinalizing {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().tint(Theme.textSecondary)
                    Text("Finishing video").foregroundStyle(Theme.textSecondary)
                }
                .font(.subheadline)
            }
            PrimaryButton(startTitle, systemImage: "record.circle", tint: isUnusual ? Theme.amber : Theme.volt) {
                focus = nil
                viewModel.start(setup: currentSetup)
            }
            .disabled(!canStart)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
        .background(
            Theme.ink900
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var currentSetup: RecordingSetup {
        RecordingSetup(
            kind: kind,
            subject: trimmedSubject,
            tags: RecordedSession.Tags(
                lighting: lighting,
                distance: distance,
                clothing: clothing,
                tempo: tempo,
                variant: RecordedSession.Tags.variant(hands: hands, support: support, width: width),
                cheat: effectiveCheat,
                hands: hands,
                support: support,
                width: width
            ),
            poseLabel: poseLabel,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            saveVideo: saveVideo && viewModel.isVideoAvailable,
            countVisible: countVisible
        )
    }
}
#endif
