#if DEBUG
import AVFoundation
import PushupCore
import SwiftUI

/// DEBUG-only data-collection mode: records labeled landmark sessions and
/// writes them to the app's Documents directory in the exact JSON schema
/// `training/dataset.py` expects (see `training/README.md` section 1),
/// then offers a `ShareLink` to get each recording off-device. Not
/// reachable from Release builds.
struct RecordingView: View {
    @StateObject private var viewModel = RecordingViewModel()
    @State private var selectedLabel: PoseLabel = .up
    @State private var source: String = ""
    @State private var pendingDeleteURL: URL?

    private static let labelOptions: [(PoseLabel, String)] = [
        (.up, "Up (top position, arms extended)"),
        (.down, "Down (bottom position, chest low)"),
        (.notPushup, "Not a pushup (standing, sitting, etc.)"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            cameraPreviewCard

            Form {
                Section("Label") {
                    Picker("Pose", selection: $selectedLabel) {
                        ForEach(Self.labelOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    .pickerStyle(.inline)
                    .disabled(viewModel.isRecording)
                }

                Section("Source (free text — device, person, notes)") {
                    TextField("e.g. iPhone 14 Pro, Aditya, kitchen floor", text: $source)
                        .disabled(viewModel.isRecording)
                }

                Section {
                    if viewModel.isRecording {
                        HStack {
                            Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            Text("Recording — \(viewModel.recordedFrameCount) frames")
                        }
                        Button("Stop recording") {
                            viewModel.stopAndSave(label: selectedLabel, source: source)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button("Start recording") {
                            viewModel.start()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section("Saved sessions") {
                    if viewModel.savedFiles.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.savedFiles, id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent)
                                .font(.footnote)
                                .lineLimit(1)
                            Spacer()
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Button {
                                pendingDeleteURL = url
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in
                        viewModel.deleteSavedFiles(at: offsets)
                    }
                }
            }
        }
        .navigationTitle("Data collection")
        .onAppear {
            viewModel.refreshSavedFiles()
            viewModel.startCamera()
        }
        .onDisappear {
            viewModel.stopCamera()
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
                    viewModel.deleteSavedFile(url)
                }
                pendingDeleteURL = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteURL = nil
            }
        }
    }

    /// Live camera preview + skeleton overlay + a small "body
    /// detected" indicator, shown near the top of the screen so the user
    /// can frame themselves before hitting "Start recording". The camera
    /// runs for the lifetime of this view (started `onAppear`, stopped
    /// `onDisappear`), not just while recording.
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
}

/// One recorded frame in the on-disk schema: `t` in seconds since the
/// recording started, `joints` keyed by `JointName.rawValue` with
/// `[x, y, confidence]` values. Field names and shape are a contract with
/// `training/dataset.py` / `training/features.py` — do not rename.
private struct RecordedFrame: Codable {
    let t: Double
    let joints: [String: [Double]]
}

/// One recording session document, matching the schema documented in
/// `training/README.md`.
private struct RecordingSessionDocument: Codable {
    let label: String
    let source: String
    let frames: [RecordedFrame]
}

@MainActor
final class RecordingViewModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordedFrameCount = 0
    @Published var errorMessage: String?
    @Published private(set) var savedFiles: [URL] = []
    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var isBodyDetected: Bool = false

    private let cameraSession = CameraPoseSession()
    private var frames: [RecordedFrame] = []
    private var recordingStartDate: Date?
    private var isCameraActive = false

    /// Recognized filename prefixes for files this view model itself
    /// wrote (`PoseLabel` raw values), used to keep deletion scoped to
    /// recordings this screen produced rather than any arbitrary file
    /// that happens to live in Documents.
    private static let recordingLabelPrefixes = ["up", "down", "not_pushup"]

    init() {
        cameraSession.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
        }
    }

    /// Single preview layer for this view model's lifetime. Must not be
    /// recreated per SwiftUI render: only the first layer ever gets added
    /// to the view's layer tree, so a fresh layer per `body` evaluation
    /// leaves the on-screen one unsized (blank preview).
    lazy var previewLayer: AVCaptureVideoPreviewLayer = cameraSession.makePreviewLayer()

    /// Starts the live camera/pose pipeline so the preview and skeleton
    /// overlay are live before the user commits to recording. Safe to
    /// call repeatedly (e.g. from `onAppear` and again from `start()` as
    /// a retry if an earlier attempt failed).
    func startCamera() {
        guard !isCameraActive else { return }
        isCameraActive = true
        cameraSession.start { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.errorMessage = "Camera error: \(error)"
                self.isCameraActive = false
            }
        }
    }

    func stopCamera() {
        cameraSession.stop()
        isCameraActive = false
        isRecording = false
    }

    func start() {
        errorMessage = nil
        frames = []
        recordedFrameCount = 0
        recordingStartDate = Date()
        isRecording = true
        startCamera()
    }

    func stopAndSave(label: PoseLabel, source: String) {
        isRecording = false

        guard !frames.isEmpty else {
            errorMessage = "No frames recorded — nothing saved."
            return
        }

        let document = RecordingSessionDocument(
            label: label.rawValue,
            source: source,
            frames: frames
        )

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(document)
            try writeToDocuments(data: data, label: label.rawValue)
            refreshSavedFiles()
        } catch {
            errorMessage = "Failed to save recording: \(error.localizedDescription)"
        }
    }

    func refreshSavedFiles() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            savedFiles = []
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        savedFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Deletes one saved recording (trash button path).
    func deleteSavedFile(_ url: URL) {
        removeFileIfManaged(url)
        refreshSavedFiles()
    }

    /// Deletes saved recordings at the given list indices (swipe-to-delete
    /// path).
    func deleteSavedFiles(at offsets: IndexSet) {
        for index in offsets {
            guard savedFiles.indices.contains(index) else { continue }
            removeFileIfManaged(savedFiles[index])
        }
        refreshSavedFiles()
    }

    /// Only ever removes files inside the app's Documents directory whose
    /// name matches the pattern `writeToDocuments` writes
    /// (`<label>_<timestamp>.json`), so a delete tap can never reach
    /// outside the recordings this screen owns.
    private func removeFileIfManaged(_ url: URL) {
        guard isManagedRecordingFile(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func isManagedRecordingFile(_ url: URL) -> Bool {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        guard url.deletingLastPathComponent().standardizedFileURL == documentsURL.standardizedFileURL else {
            return false
        }
        guard url.pathExtension == "json" else { return false }
        let filename = url.deletingPathExtension().lastPathComponent
        return Self.recordingLabelPrefixes.contains { filename.hasPrefix("\($0)_") }
    }

    private func handle(frame: PoseFrame) {
        latestFrame = frame
        isBodyDetected = !frame.joints.isEmpty

        guard isRecording, let start = recordingStartDate else { return }
        let t = Date().timeIntervalSince(start)
        var joints: [String: [Double]] = [:]
        for (name, point) in frame.joints {
            joints[name.rawValue] = [Double(point.x), Double(point.y), Double(point.confidence)]
        }
        frames.append(RecordedFrame(t: t, joints: joints))
        recordedFrameCount = frames.count
    }

    private func writeToDocuments(data: Data, label: String) throws {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "\(label)_\(timestamp).json"
        let url = documentsURL.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
    }
}

#Preview {
    NavigationStack {
        RecordingView()
    }
}
#endif
