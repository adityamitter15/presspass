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
    /// Whether to save the camera video of this take as well. Ignored when
    /// the pose source has no camera.
    var saveVideo: Bool
    /// Whether the app's live count is shown on screen (and sounded) while
    /// this take is recorded. Stored in the session as `countVisible`.
    var countVisible: Bool
}

/// A finished take waiting for the user to save or discard it. Holds only
/// what the UI may show: the app's own count lives privately in the view
/// model so it can never reach the screen before the true count is entered.
/// The tags can still be corrected while it waits.
struct PendingTake: Identifiable, Equatable {
    let id: String
    let kind: RecordedSession.Kind
    let subject: String
    let poseLabel: PoseLabel
    var tags: RecordedSession.Tags
    let frameCount: Int
    let duration: TimeInterval
    let stoppedAutomatically: Bool
}

/// Shown on the setup screen after a take is saved. This is the one place the
/// app's count appears next to the true one, and only once the take is saved.
struct SavedNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Total of what has been saved so far, to track progress against a target.
struct RecordingTotals: Equatable {
    var people = 0
    var sets = 0
    var trueReps = 0
    var negatives = 0
    var poses = 0

    init() {}

    init(_ summaries: [RecordingSummary]) {
        people = Set(summaries.map { $0.subject.trimmingCharacters(in: .whitespaces).uppercased() }).count
        for summary in summaries {
            switch summary.kind {
            case .set:
                sets += 1
                trueReps += summary.trueReps ?? 0
            case .negative:
                negatives += 1
            case .pose:
                poses += 1
            case .workout:
                break
            }
        }
    }
}

/// Drives the DEBUG recorder screen. Owns the camera session, records the
/// raw landmark stream, the phone's own motion and (optionally) the camera
/// video while a take is running, and runs the same pipeline
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
    /// True between Stop and the take becoming pending, while the video file
    /// is being completed. Nothing is shown for it beyond a status line.
    @Published private(set) var isFinalizing = false
    @Published private(set) var isSaving = false
    @Published private(set) var saved: [RecordingSummary] = []
    @Published private(set) var totals = RecordingTotals()
    /// What the live screen shows. In a blind take `shownReps` stays 0 and
    /// the shallow flash never fires: the count is not published at all.
    @Published private(set) var liveDepth: Double = 0
    @Published private(set) var shownReps = 0
    @Published private(set) var isShallowFlash = false
    /// Whether the take now running shows the count.
    @Published private(set) var activeCountVisible = false
    @Published private(set) var savedNotice: SavedNotice?
    /// What the running take was tagged as, for a line on the live screen.
    @Published private(set) var activeTakeLabel = ""
    @Published private(set) var activeTakeIsUnusual = false
    @Published private(set) var isExporting = false
    @Published var errorMessage: String?
    /// Set while the system has taken the camera away, with the reason.
    @Published private(set) var cameraNotice: String?
    /// Something that did not stop a take being saved, such as a video that
    /// could not be kept. Never carries a count.
    @Published private(set) var warningMessage: String?

    private let poseSource: PoseSource
    private let motionRecorder = MotionRecorder()
    private let store = RecordingStore(
        demoSummaries: AppEnvironment.current.demoRecordings ? RecordingDemo.takes : nil
    )
    private let liveFeedback = RecorderLiveFeedback()
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
    private var takeMotion: MotionStream?

    // The video of the active or pending take. The writer is fed from the
    // camera's processing queue and does its own locking; everything else
    // here is main-queue state.
    private var takeVideoWriter: VideoTakeWriter?
    private var takeVideoURL: URL?
    private var takeVideoResult: Result<VideoTakeWriter.Summary, Error>?

    /// Whether this device can supply device motion, shown as a status line.
    let isMotionAvailable: Bool
    /// Whether takes can carry video: only with a real camera, not a replay.
    let isVideoAvailable: Bool

    init(poseSource: PoseSource = AppEnvironment.current.makePoseSource()) {
        self.poseSource = poseSource
        isMotionAvailable = motionRecorder.isAvailable
        isVideoAvailable = poseSource is CameraPoseSession
        poseSource.onInterruption = { [weak self] message in
            self?.cameraNotice = message
        }
        poseSource.onRawFrame = { [weak self] raw in
            self?.handle(raw: raw)
        }
    }

    /// Single preview layer for this view model's lifetime. Must not be
    /// recreated per SwiftUI render: only the first layer ever gets added
    /// to the view's layer tree, so a fresh layer per `body` evaluation
    /// leaves the on-screen one unsized (blank preview). Nil when the source
    /// has no camera image (replay).
    lazy var previewLayer: AVCaptureVideoPreviewLayer? = poseSource.makePreviewLayer()

    // MARK: - Camera

    /// Starts the live camera/pose pipeline so the preview and skeleton
    /// overlay are live before the user commits to recording. Safe to
    /// call repeatedly (e.g. from `onAppear` and again from `start` as
    /// a retry if an earlier attempt failed).
    func startCamera() {
        guard !isCameraActive else { return }
        isCameraActive = true
        motionRecorder.start()
        poseSource.start { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                switch error {
                case .notAuthorized:
                    self.errorMessage = "Camera access is required. Enable it in Settings."
                case .cameraUnavailable:
                    self.errorMessage = "No front camera is available on this device."
                }
                self.isCameraActive = false
                self.motionRecorder.stop()
            }
        }
    }

    /// Stops the camera. A take still in progress is dropped, since leaving
    /// the screen mid-set means it is not a usable recording.
    func stopCamera() {
        poseSource.stop()
        motionRecorder.stop()
        isCameraActive = false
        if isRecording {
            isRecording = false
            _ = motionRecorder.endTake()
            frames = []
            pipeline = nil
            discardTakeVideo()
            liveFeedback.end()
        }
    }

    /// Throws away the take in progress (after the user confirmed), removing
    /// its temporary video, and goes back to setup. The camera stays on.
    func cancelTake() {
        guard isRecording else { return }
        isRecording = false
        _ = motionRecorder.endTake()
        frames = []
        pipeline = nil
        setup = nil
        recordedFrameCount = 0
        elapsedSeconds = 0
        discardTakeVideo()
        liveFeedback.end()
        resetLiveDisplay()
        RecorderPrefs.resetCheat()
    }

    // MARK: - Recording

    func start(setup: RecordingSetup) {
        guard !isRecording, !isFinalizing, pendingTake == nil else { return }
        errorMessage = nil
        warningMessage = nil
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
        takeMotion = nil
        savedNotice = nil
        resetLiveDisplay()
        activeCountVisible = setup.countVisible
        activeTakeLabel = RecorderCopy.liveLabel(setup)
        activeTakeIsUnusual = RecorderCopy.isUnusual(kind: setup.kind, cheat: setup.tags.cheat)
        liveFeedback.begin(countVisible: setup.countVisible)
        beginTakeVideo(if: setup.saveVideo)
        isRecording = true
        startCamera()
        motionRecorder.beginTake()
    }

    func stop() {
        finishRecording(automatically: false)
    }

    private func finishRecording(automatically: Bool) {
        guard isRecording, let setup else { return }
        isRecording = false
        pipeline = nil
        liveFeedback.end()
        let buffered = motionRecorder.endTake()
        // Stop feeding the writer first. A frame the camera queue is handing
        // over right now is harmless: the writer ignores it once finished.
        poseSource.onSampleBuffer = nil

        guard let last = frames.last else {
            errorMessage = "No frames were recorded, nothing to save."
            frames = []
            discardTakeVideo()
            resetLiveDisplay()
            RecorderPrefs.resetCheat()
            return
        }
        takeMotion = Self.motionStream(from: buffered, originPresentationTime: originPresentationTime)
        let take = PendingTake(
            id: takeID,
            kind: setup.kind,
            subject: setup.subject,
            poseLabel: setup.poseLabel,
            tags: setup.tags,
            frameCount: frames.count,
            duration: last.t,
            stoppedAutomatically: automatically
        )

        guard let writer = takeVideoWriter else {
            pendingTake = take
            return
        }
        // Hold the take until the video file is complete, so the save sheet
        // never opens on a half-written file.
        isFinalizing = true
        let videoURL = takeVideoURL
        writer.finish { [weak self] result in
            guard let self else {
                if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
                return
            }
            guard self.isFinalizing, self.takeID == take.id else { return }
            self.isFinalizing = false
            self.takeVideoWriter = nil
            self.takeVideoResult = result
            self.pendingTake = take
        }
    }

    /// Throws the pending take away.
    func discardPending() {
        guard !isSaving else { return }
        pendingTake = nil
        frames = []
        takeMotion = nil
        setup = nil
        discardTakeVideo()
        resetLiveDisplay()
        RecorderPrefs.resetCheat()
    }

    /// Changes the tags of the take waiting to be saved, in case they were
    /// wrong at Start. Only the tags of a set can differ from what the kind
    /// forces, and `savePending` applies that rule again.
    func updatePendingTags(_ tags: RecordedSession.Tags) {
        guard pendingTake != nil, !isSaving else { return }
        setup?.tags = tags
        pendingTake?.tags = tags
    }

    func dismissNotice() {
        savedNotice = nil
    }

    private func resetLiveDisplay() {
        liveDepth = 0
        shownReps = 0
        isShallowFlash = false
        activeCountVisible = false
    }

    // MARK: - Video

    /// Creates this take's writer and starts feeding it camera frames.
    private func beginTakeVideo(if wanted: Bool) {
        discardTakeVideo()
        guard wanted, isVideoAvailable else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(takeID).mp4")
        let writer = VideoTakeWriter(outputURL: url)
        takeVideoWriter = writer
        takeVideoURL = url
        // A method reference, not a closure written here: this class is
        // main-actor isolated and the camera calls this on its own queue.
        // The writer does its own locking.
        poseSource.onSampleBuffer = writer.append
    }

    /// Stops feeding the writer and throws away the take's video, including
    /// the temporary file.
    private func discardTakeVideo() {
        poseSource.onSampleBuffer = nil
        takeVideoWriter?.cancel()
        takeVideoWriter = nil
        if let url = takeVideoURL { try? FileManager.default.removeItem(at: url) }
        takeVideoURL = nil
        takeVideoResult = nil
    }

    /// What to store for the pending take's video, or why there is none.
    /// `startPts` puts the video on the same clock as `frames[].pts`: both are
    /// camera presentation times, so it is the video's first frame minus the
    /// first recorded pose frame.
    private func videoForSaving() -> (info: VideoInfo, url: URL)? {
        guard let result = takeVideoResult, let url = takeVideoURL else { return nil }
        switch result {
        case .success(let summary):
            guard let origin = originPresentationTime, origin.isFinite,
                  summary.firstPresentationTime.isNumeric else {
                warningMessage = "Saved without video: the camera gave no timestamp to line it up with."
                return nil
            }
            let info = VideoInfo(
                file: "",
                width: summary.width,
                height: summary.height,
                codec: "h264",
                frameCount: summary.frameCount,
                startPts: summary.firstPresentationTime.seconds - origin
            )
            return (info, url)
        case .failure(let error):
            warningMessage = "Saved without video: \(error.localizedDescription)"
            return nil
        }
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
        case .pose, .workout:
            storedReps = nil
        }

        let isSet = setup.kind == .set
        var tags = setup.tags
        if !isSet {
            tags.tempo = .na
            tags.variant = .na
            tags.cheat = .none
            tags.hands = nil
            tags.support = nil
            tags.width = nil
        }
        warningMessage = nil
        // Only keep the video if its file is still where the writer left it.
        // A failed save moves it back, but if that was impossible it is gone.
        var video = videoForSaving()
        if let found = video, !FileManager.default.fileExists(atPath: found.url.path) {
            warningMessage = "Saved without video: the video file was missing."
            video = nil
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
            frames: frames,
            motion: takeMotion,
            video: video?.info,
            countVisible: setup.countVisible
        )
        let videoURL = video?.url
        let notice = Self.noticeText(
            subject: setup.subject, kind: setup.kind, trueReps: storedReps, appReps: liveReps
        )

        errorMessage = nil
        isSaving = true
        let store = store
        ioQueue.async { [weak self] in
            let result = Result { try store.save(session, temporaryVideo: videoURL) }
            let summaries = store.list()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                switch result {
                case .success:
                    self.pendingTake = nil
                    self.frames = []
                    self.takeMotion = nil
                    self.setup = nil
                    // The video file now lives in the recordings directory.
                    self.takeVideoURL = nil
                    self.takeVideoResult = nil
                    self.savedNotice = SavedNotice(text: notice)
                    self.resetLiveDisplay()
                    RecorderPrefs.resetCheat()
                    self.publish(summaries)
                case .failure(let error):
                    // The take stays pending so the user can retry.
                    self.warningMessage = nil
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

    /// The sentence shown after a save. Only now may the app's count appear.
    private static func noticeText(subject: String, kind: RecordedSession.Kind, trueReps: Int?, appReps: Int) -> String {
        switch kind {
        case .set:
            return "Saved \(subject): you counted \(trueReps ?? 0), app counted \(appReps)"
        case .negative:
            return "Saved \(subject): negative take, app counted \(appReps)"
        case .pose:
            return "Saved \(subject): held pose"
        case .workout:
            return "Saved \(subject): app workout"
        }
    }

    /// The label fields an edit may change. Everything else in a take is
    /// untouchable, see `RecordingStore.updateLabels`.
    struct LabelEdit: Sendable {
        var trueReps: Int?
        var subject: String
        var tags: RecordedSession.Tags
        var notes: String
        var poseLabel: PoseLabel?
    }

    /// Rewrites the labels of one saved take off the main queue. `completion`
    /// gets nil on success or the reason it failed, on the main queue.
    func updateLabels(of url: URL, _ edit: LabelEdit, completion: @escaping (String?) -> Void) {
        let store = store
        ioQueue.async { [weak self] in
            let result = Result {
                try store.updateLabels(of: url) { session in
                    session.trueReps = edit.trueReps
                    session.subject = edit.subject
                    session.tags = edit.tags
                    session.notes = edit.notes
                    session.poseLabel = edit.poseLabel
                }
            }
            let summaries = store.list()
            DispatchQueue.main.async {
                guard let self else { return }
                self.publish(summaries)
                switch result {
                case .success: completion(nil)
                case .failure(let error): completion("Could not save the changes: \(error.localizedDescription)")
                }
            }
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

        let repsBefore = liveReps
        if let output = pipeline?.process(poseFrame) {
            liveReps = output.reps
            liveRejectedReps = output.rejectedReps
            // Display only: depth for the ring and, if the take shows the
            // count, the count and its sounds. Nothing here is recorded.
            liveFeedback.process(output, repsBefore: repsBefore, timestamp: raw.timestamp)
            let snapshot = liveFeedback.snapshot
            if liveDepth != snapshot.depth { liveDepth = snapshot.depth }
            if shownReps != snapshot.reps { shownReps = snapshot.reps }
            if isShallowFlash != snapshot.isShallow { isShallowFlash = snapshot.isShallow }
        }

        let elapsed = raw.timestamp - originTimestamp
        elapsedSeconds = elapsed
        if elapsed >= Self.maxDuration {
            finishRecording(automatically: true)
        }
    }

    // MARK: - Motion

    /// Puts the buffered samples on the pose timeline. `CMDeviceMotion`
    /// timestamps and the camera's `CMSampleBuffer` presentation times are
    /// both host-clock seconds since boot, so a sample's `t` is just its
    /// timestamp minus the first recorded frame's presentation time. `t` can
    /// be slightly negative for samples taken between Start and that frame.
    /// nil when the first frame had no presentation time or nothing was
    /// buffered (no motion hardware).
    private static func motionStream(
        from samples: [MotionRecorder.Sample],
        originPresentationTime: TimeInterval?
    ) -> MotionStream? {
        guard let origin = originPresentationTime, origin.isFinite, !samples.isEmpty else { return nil }
        var stream = MotionStream(rateHz: MotionRecorder.updateRateHz)
        stream.samples.reserveCapacity(samples.count * MotionStream.stride)
        for sample in samples {
            stream.append(
                t: sample.timestamp - origin,
                userAcceleration: sample.userAcceleration,
                rotationRate: sample.rotationRate,
                gravity: sample.gravity
            )
        }
        return stream.sampleCount > 0 ? stream : nil
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
