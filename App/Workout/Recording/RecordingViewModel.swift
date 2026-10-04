#if DEBUG
import AVFoundation
import Combine
import Foundation
import PushupCore
import UIKit

/// Everything the user chose before pressing Start, captured when the
/// recording begins.
struct RecordingSetup {
    var kind: RecordedSession.Kind
    var subject: String
    var tags: RecordedSession.Tags
    var poseLabel: PoseLabel
    var notes: String
}

/// A finished take waiting for the user to save or discard it. Holds only
/// what the UI may show: the app's own count lives privately in the view
/// model so it can never reach the screen before the true count is entered.
struct PendingTake: Identifiable, Equatable {
    let id: String
    let kind: RecordedSession.Kind
    let frameCount: Int
    let duration: TimeInterval
    let stoppedAutomatically: Bool
}

/// Total of what has been saved so far, to track progress against a target.
struct RecordingTotals: Equatable {
    var sets = 0
    var trueReps = 0
    var negatives = 0
    var poses = 0

    init() {}

    init(_ summaries: [RecordingSummary]) {
        for summary in summaries {
            switch summary.kind {
            case .set:
                sets += 1
                trueReps += summary.trueReps ?? 0
            case .negative:
                negatives += 1
            case .pose:
                poses += 1
            }
        }
    }
}

/// Drives the DEBUG recorder screen. Owns the camera session, records the
/// raw landmark stream while a take is running, and runs the same pipeline
/// the workout screen uses so the app's count can be stored next to the
/// human-entered one. Camera callbacks arrive on the main queue; encoding
/// and file work run on a utility queue and publish back on main.
@MainActor
final class RecordingViewModel: ObservableObject {
    /// Recording stops by itself after this many seconds.
    static let maxDuration: TimeInterval = 300

    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var isBodyDetected = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordedFrameCount = 0
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var pendingTake: PendingTake?
    @Published private(set) var isSaving = false
    @Published private(set) var saved: [RecordingSummary] = []
    @Published private(set) var totals = RecordingTotals()
    @Published private(set) var isExporting = false
    @Published var errorMessage: String?

    private let cameraSession = CameraPoseSession()
    private let store = RecordingStore()
    private let ioQueue = DispatchQueue(label: "com.addymitter.pushuptime.recorder.io", qos: .utility)
    private var isCameraActive = false

    // The active or pending take. The live results are deliberately not
    // @Published and have no accessor: blind labelling.
    private var setup: RecordingSetup?
    private var frames: [RecordedFrame] = []
    private var originTimestamp: TimeInterval = 0
    private var originPresentationTime: TimeInterval?
    private var pipeline: PushupPipeline?
    private var liveReps = 0
    private var liveRejectedReps = 0
    private var liveClassifier = "heuristic"
    private var takeID = ""
    private var takeCreatedAt = Date()
    private var takeDevice: DeviceInfo?

    init() {
        cameraSession.onRawFrame = { [weak self] raw in
            self?.handle(raw: raw)
        }
    }

    /// Single preview layer for this view model's lifetime. Must not be
    /// recreated per SwiftUI render: only the first layer ever gets added
    /// to the view's layer tree, so a fresh layer per `body` evaluation
    /// leaves the on-screen one unsized (blank preview).
    lazy var previewLayer: AVCaptureVideoPreviewLayer = cameraSession.makePreviewLayer()

    // MARK: - Camera

    /// Starts the live camera/pose pipeline so the preview and skeleton
    /// overlay are live before the user commits to recording. Safe to
    /// call repeatedly (e.g. from `onAppear` and again from `start` as
    /// a retry if an earlier attempt failed).
    func startCamera() {
        guard !isCameraActive else { return }
        isCameraActive = true
        cameraSession.start { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                switch error {
                case .notAuthorized:
                    self.errorMessage = "Camera access is required. Enable it in Settings."
                case .cameraUnavailable:
                    self.errorMessage = "No front camera is available on this device."
                }
                self.isCameraActive = false
            }
        }
    }

    /// Stops the camera. A take still in progress is dropped, since leaving
    /// the screen mid-set means it is not a usable recording.
    func stopCamera() {
        cameraSession.stop()
        isCameraActive = false
        if isRecording {
            isRecording = false
            frames = []
            pipeline = nil
        }
    }

    // MARK: - Recording

    func start(setup: RecordingSetup) {
        guard !isRecording, pendingTake == nil else { return }
        errorMessage = nil
        self.setup = setup
        frames = []
        recordedFrameCount = 0
        elapsedSeconds = 0
        liveReps = 0
        liveRejectedReps = 0
        // A fresh pipeline, not just a reset one, so the classifier's own
        // state does not carry over from the previous take. This matches a
        // replay, which always starts from a new pipeline.
        let classifier = PoseClassifierFactory.makeDefault()
        liveClassifier = classifier is CoreMLPoseClassifier ? "coreml" : "heuristic"
        pipeline = PushupPipeline(classifier: classifier)
        takeID = UUID().uuidString
        takeCreatedAt = Date()
        takeDevice = Self.deviceInfo()
        isRecording = true
        startCamera()
    }

    func stop() {
        finishRecording(automatically: false)
    }

    private func finishRecording(automatically: Bool) {
        guard isRecording, let setup else { return }
        isRecording = false
        pipeline = nil

        guard let last = frames.last else {
            errorMessage = "No frames were recorded, nothing to save."
            frames = []
            return
        }
        pendingTake = PendingTake(
            id: takeID,
            kind: setup.kind,
            frameCount: frames.count,
            duration: last.t,
            stoppedAutomatically: automatically
        )
    }

    /// Throws the pending take away.
    func discardPending() {
        guard !isSaving else { return }
        pendingTake = nil
        frames = []
        setup = nil
    }

    /// Writes the pending take. `trueReps` is the human-entered count: required
    /// (0 to 300) for a set, ignored for the other kinds.
    func savePending(trueReps: Int?) {
        guard let take = pendingTake, let setup, let device = takeDevice, !isSaving else { return }

        let storedReps: Int?
        switch setup.kind {
        case .set:
            guard let trueReps, (0...300).contains(trueReps) else {
                errorMessage = "Enter the number of reps, from 0 to 300."
                return
            }
            storedReps = trueReps
        case .negative:
            storedReps = 0
        case .pose:
            storedReps = nil
        }

        let isSet = setup.kind == .set
        var tags = setup.tags
        if !isSet {
            tags.tempo = .na
            tags.variant = .na
            tags.cheat = .none
        }
        let session = RecordedSession(
            id: take.id,
            createdAt: RecordedSession.iso8601String(from: takeCreatedAt),
            kind: setup.kind,
            trueReps: storedReps,
            poseLabel: setup.kind == .pose ? setup.poseLabel : nil,
            subject: setup.subject,
            tags: tags,
            notes: setup.notes,
            device: device,
            live: LiveResult(reps: liveReps, rejectedReps: liveRejectedReps, classifier: liveClassifier),
            frames: frames
        )

        errorMessage = nil
        isSaving = true
        let store = store
        ioQueue.async { [weak self] in
            let result = Result { try store.save(session) }
            let summaries = store.list()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                switch result {
                case .success:
                    self.pendingTake = nil
                    self.frames = []
                    self.setup = nil
                    self.publish(summaries)
                case .failure(let error):
                    // The take stays pending so the user can retry.
                    self.errorMessage = "Failed to save recording: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Saved sessions

    func refreshSaved() {
        let store = store
        ioQueue.async { [weak self] in
            let summaries = store.list()
            DispatchQueue.main.async { self?.publish(summaries) }
        }
    }

    func delete(_ urls: [URL]) {
        let store = store
        ioQueue.async { [weak self] in
            var failure: Error?
            for url in urls {
                do { try store.delete(url) } catch { failure = error }
            }
            let summaries = store.list()
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    self.errorMessage = "Failed to delete recording: \(failure.localizedDescription)"
                }
                self.publish(summaries)
            }
        }
    }

    /// Builds the zip off the main queue and hands back its URL.
    func exportAll(completion: @escaping (URL) -> Void) {
        guard !isExporting else { return }
        errorMessage = nil
        isExporting = true
        let store = store
        ioQueue.async { [weak self] in
            let result = Result { try store.exportArchive() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success(let url):
                    completion(url)
                case .failure(let error):
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func publish(_ summaries: [RecordingSummary]) {
        saved = summaries
        totals = RecordingTotals(summaries)
    }

    // MARK: - Frames

    private func handle(raw: RawPoseFrame) {
        let poseFrame = BlazePoseMapping.poseFrame(from: raw)
        latestFrame = poseFrame
        isBodyDetected = !poseFrame.joints.isEmpty

        guard isRecording else { return }

        if frames.isEmpty {
            originTimestamp = raw.timestamp
            originPresentationTime = raw.presentationTime
        }
        frames.append(RecordedFrame(raw: raw, originTimestamp: originTimestamp, originPresentationTime: originPresentationTime))
        recordedFrameCount = frames.count

        if let output = pipeline?.process(poseFrame) {
            liveReps = output.reps
            liveRejectedReps = output.rejectedReps
        }

        let elapsed = raw.timestamp - originTimestamp
        elapsedSeconds = elapsed
        if elapsed >= Self.maxDuration {
            finishRecording(automatically: true)
        }
    }

    // MARK: - Device

    private static func deviceInfo() -> DeviceInfo {
        let info = Bundle.main.infoDictionary
        return DeviceInfo(
            model: hardwareIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            poseModel: "pose_landmarker_full",
            cameraPosition: "front",
            featureVersion: PushupFeatureExtractor.featureVersion
        )
    }

    /// The `uname` machine string, for example "iPhone17,2". In the
    /// simulator that is the host architecture, so the simulated model is
    /// used instead when it is available.
    private static func hardwareIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        var system = utsname()
        uname(&system)
        var machine = system.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
#endif
