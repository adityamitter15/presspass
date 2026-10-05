import AVFoundation
import Combine
import Foundation
import PushupCore
import UIKit

/// A line of guidance shown while a set is running.
enum WorkoutHint: Equatable {
    /// Nobody is in the frame.
    case noBody
    /// A body is there but the wrists, shoulders or hips are not clear.
    case armsHidden
    /// The hands are not on the floor under the shoulders.
    case handsPosition
    /// The last descent was not low enough to count.
    case shallow
    /// Not at the top yet: the arms are not straight.
    case holdTheTop

    var text: String {
        switch self {
        case .noBody: "Step back so I can see you"
        case .armsHidden: "I can't see your arms"
        case .handsPosition: "Hands on the floor, under your shoulders"
        case .shallow: "Go lower"
        case .holdTheTop: "Arms straight, hold the top position"
        }
    }

    var systemImage: String {
        switch self {
        case .noBody: "person.fill.questionmark"
        case .armsHidden: "eye.slash.fill"
        case .handsPosition: "hand.raised.fill"
        case .shallow: "arrow.down.to.line"
        case .holdTheTop: "arrow.up.to.line"
        }
    }

    var tone: HintPill.Tone {
        switch self {
        case .noBody, .armsHidden: .coral
        case .handsPosition, .holdTheTop: .neutral
        case .shallow: .amber
        }
    }
}

extension WorkoutHint {
    /// What the engine's hint looks like on screen.
    init(_ hint: WorkoutSessionEngine.Hint) {
        switch hint {
        case .stepBack: self = .noBody
        case .cannotSeeArms: self = .armsHidden
        case .handsOnFloor: self = .handsPosition
        case .holdTheTop: self = .holdTheTop
        case .goLower: self = .shallow
        }
    }
}

extension WorkoutSessionEngine.Phase {
    /// The set is under way: counting, or counting down to finish.
    var isCounting: Bool {
        switch self {
        case .active, .finishing: true
        case .positioning, .finished: false
        }
    }
}

/// What the depth ring is showing besides the depth itself.
enum RingState: Equatable {
    case tracking
    /// A shallow attempt, flashed amber.
    case shallow
}

/// Why there is no camera picture.
enum CameraIssue: Equatable {
    case notAuthorized
    case unavailable
    /// The system has taken the camera away for now. Clears by itself.
    case interrupted(String)
}

/// Drives one workout for `WorkoutView`: it feeds the pose source's frames to
/// a `WorkoutSessionEngine`, which owns all the workout logic (when counting
/// starts, what is counted, hints, when the set ends), and publishes what the
/// engine reports. Everything here runs synchronously on the delivery queue's
/// callback, cheap enough per frame, and keeping it on the main queue means
/// the `@Published` updates below don't need an extra hop. All timing uses
/// frame timestamps, so there are no timers to keep in step.
final class WorkoutViewModel: ObservableObject {
    // MARK: Published state

    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var isBodyDetected: Bool = false
    /// The frame passes every posture check: hands on the floor, planted, body horizontal.
    @Published private(set) var isPostureValid: Bool = false
    /// 0 to 1 over the engine's start hold, while positioning.
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var phase: WorkoutSessionEngine.Phase = .positioning
    /// Smoothed depth, 0 (arms straight) to 1 (low enough to count).
    @Published private(set) var depth: Double = 0
    @Published private(set) var ringState: RingState = .tracking
    @Published private(set) var hint: WorkoutHint?
    /// Whole seconds since the set became active.
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var reps: Int = 0
    @Published private(set) var shallowAttempts: Int = 0
    /// True for a moment when the set becomes active.
    @Published private(set) var showsGo: Bool = false
    @Published private(set) var rejectedReps: Int = 0
    @Published private(set) var currentLabel: PoseLabel = .notPushup
    @Published private(set) var ignoreReason: RepCounterIgnoreReason = .none
    @Published private(set) var isRunning: Bool = false {
        // The phone sits untouched on the floor during a set, so it must not
        // auto-lock while a workout is running. Every path that ends a
        // workout (finish, view disappearing, camera failure) clears
        // `isRunning`, which restores the default.
        didSet { UIApplication.shared.isIdleTimerDisabled = isRunning }
    }
    @Published private(set) var cameraIssue: CameraIssue?

    #if DEBUG
    /// Live engine internals for the on-screen debug HUD.
    @Published private(set) var debugStatus: String = ""
    #endif

    /// One minute earned per counted rep.
    var minutesEarned: Int { reps }

    /// Length of the finishing countdown, for the ring.
    var finishingCountdown: Double { engine.config.finishingCountdown }

    // MARK: Collaborators

    private let poseSource: PoseSource
    private var engine: WorkoutSessionEngine
    private let makeEngine: () -> WorkoutSessionEngine
    private var audio: WorkoutAudio?
    #if DEBUG
    private let flightRecorder = WorkoutFlightRecorder()
    private var recordsFlight = false
    #endif

    // MARK: Display bookkeeping

    /// How long the "Go" flash stays, a presentation detail.
    private static let goSeconds: TimeInterval = 0.9

    private var startedAt: Date?
    private var goUntil: TimeInterval = 0
    private var hasFinished = false
    private var finishCuePlayed = false
    private var pinnedState: AppEnvironment.DebugState?
    private var wantsDebugStatus = false

    /// The engine as the app runs it: the default session config with the
    /// "Finish automatically" setting, and the bundled Core ML classifier if
    /// there is one (otherwise the engine builds the heuristic itself).
    static func makeDefaultEngine() -> WorkoutSessionEngine {
        var config = SessionConfig.default
        config.autoFinish = AppSettings.autoFinish
        return WorkoutSessionEngine(config: config, classifier: CoreMLPoseClassifier.loadFromBundle())
    }

    init(
        poseSource: PoseSource = AppEnvironment.current.makePoseSource(),
        makeEngine: @escaping () -> WorkoutSessionEngine = WorkoutViewModel.makeDefaultEngine
    ) {
        self.poseSource = poseSource
        self.makeEngine = makeEngine
        self.engine = makeEngine()
        self.poseSource.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
        }
        #if DEBUG
        self.poseSource.onRawFrame = { [weak self] raw in
            guard let self, self.recordsFlight else { return }
            self.flightRecorder.append(raw)
        }
        #endif
        self.poseSource.onInterruption = { [weak self] message in
            guard let self else { return }
            if let message {
                self.cameraIssue = .interrupted(message)
            } else if case .interrupted = self.cameraIssue {
                self.cameraIssue = nil
            }
        }
    }

    /// Single preview layer for the session's lifetime. Must not be
    /// recreated per SwiftUI render: only the first layer ever gets added
    /// to the view's layer tree, so a fresh layer per `body` evaluation
    /// leaves the on-screen one unsized (blank preview). Nil when the source
    /// has no camera image (replay).
    lazy var previewLayer: AVCaptureVideoPreviewLayer? = poseSource.makePreviewLayer()

    // MARK: Lifecycle

    func start() {
        cameraIssue = nil
        // A fresh engine per workout, so the settings are read again.
        engine = makeEngine()
        audio = WorkoutAudio(mode: AppSettings.soundMode)
        audio?.begin()

        startedAt = nil
        goUntil = 0
        hasFinished = false
        finishCuePlayed = false

        reps = 0
        rejectedReps = 0
        shallowAttempts = 0
        elapsedSeconds = 0
        depth = 0
        ringState = .tracking
        hint = nil
        showsGo = false
        holdProgress = 0
        isBodyDetected = false
        isPostureValid = false
        phase = .positioning
        currentLabel = .notPushup
        ignoreReason = .none
        #if DEBUG
        wantsDebugStatus = UserDefaults.standard.bool(forKey: AppSettings.Key.debugOverlay)
        pinnedState = AppEnvironment.current.debugState
        if let pinnedState { applyPinned(pinnedState) }
        // Every workout started from the Start button is logged; a pinned
        // screenshot state is not a workout.
        recordsFlight = pinnedState == nil
        if recordsFlight { flightRecorder.begin() }
        #endif
        isRunning = true

        poseSource.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                break
            case .failure(.notAuthorized):
                self.cameraIssue = .notAuthorized
                self.stopRunning()
            case .failure(.cameraUnavailable):
                self.cameraIssue = .unavailable
                self.stopRunning()
            }
        }
    }

    /// Stops the camera and the audio without saving anything. Safe to call
    /// more than once.
    func stop() {
        stopRunning()
    }

    /// Ends the set from the Finish button. The view sees `phase == .finished`.
    func requestFinish() {
        guard !hasFinished else { return }
        engine.finishNow()
        phase = engine.phase
    }

    /// Stops the source and returns the record of the set, or nil when no rep
    /// was counted. Plays the finishing phrase when there is a record.
    func finish() -> WorkoutSessionRecord? {
        guard !hasFinished else { return nil }
        hasFinished = true
        engine.finishNow()
        phase = .finished
        let record = makeRecord()
        // The engine reports `.finished` on its next frame. The set may well
        // be over before that frame arrives, so make sure the cue plays once.
        if record != nil { playFinishCue() }
        stopRunning()
        return record
    }

    private func stopRunning() {
        #if DEBUG
        flushFlightLog()
        #endif
        poseSource.stop()
        audio?.end()
        isRunning = false
    }

    private func playFinishCue() {
        guard !finishCuePlayed, reps > 0 else { return }
        finishCuePlayed = true
        audio?.finish()
    }

    private func makeRecord() -> WorkoutSessionRecord? {
        guard engine.reps > 0 else { return nil }
        let start = engine.activeStartTimestamp ?? 0
        let repTimes = engine.repTimes.map { max(0, $0 - start) }
        let lastRep = repTimes.last ?? 0
        let lastInPosition = engine.lastValidTimestamp.map { max(0, $0 - start) } ?? 0
        return WorkoutSessionRecord(
            startedAt: startedAt ?? Date(),
            durationSeconds: max(lastRep, lastInPosition),
            reps: engine.reps,
            repTimes: repTimes,
            shallowAttempts: engine.shallowAttempts,
            minutesEarned: engine.reps
        )
    }

    // MARK: Frames

    private func handle(frame: PoseFrame) {
        guard !hasFinished else { return }
        if let pinnedState {
            // A pinned screenshot state ignores the frames except for the
            // skeleton, which is hidden when the state says nobody is there.
            latestFrame = (pinnedState == .nobody || pinnedState == .finishing) ? nil : frame
            return
        }
        latestFrame = frame
        let timestamp = frame.timestamp
        let output = engine.process(frame)

        for event in output.events {
            switch event {
            case .started:
                startedAt = Date()
                goUntil = timestamp + Self.goSeconds
                showsGo = true
                elapsedSeconds = 0
                audio?.go()
            case .repCounted(let total):
                audio?.rep(total)
            case .shallowAttempt:
                audio?.shallowAttempt()
            case .finished:
                playFinishCue()
            case .finishingBegan, .resumed:
                break
            }
        }

        let bodyDetected = !frame.joints.isEmpty
        if isBodyDetected != bodyDetected { isBodyDetected = bodyDetected }
        let postureValid = output.gateFailure == nil
        if isPostureValid != postureValid { isPostureValid = postureValid }
        if output.phase != phase { phase = output.phase }

        let progress = output.holdProgress
        if abs(progress - holdProgress) > 0.01 || (progress == 0 && holdProgress != 0) {
            holdProgress = progress
        }

        if output.reps != reps { reps = output.reps }
        if output.rejectedReps != rejectedReps { rejectedReps = output.rejectedReps }
        if output.shallowAttempts != shallowAttempts { shallowAttempts = output.shallowAttempts }
        if let pipeline = output.pipeline {
            if currentLabel != pipeline.currentLabel { currentLabel = pipeline.currentLabel }
            if ignoreReason != pipeline.ignoreReason { ignoreReason = pipeline.ignoreReason }
        }

        let newDepth = Double(output.depth)
        if abs(newDepth - depth) > 0.002 { depth = newDepth }
        let ringNow: RingState = output.hint == .goLower ? .shallow : .tracking
        if ringState != ringNow { ringState = ringNow }

        let shown = output.hint.map(WorkoutHint.init)
        if hint != shown { hint = shown }

        if let start = engine.activeStartTimestamp, phase.isCounting {
            let seconds = Int(max(0, timestamp - start))
            if seconds != elapsedSeconds { elapsedSeconds = seconds }
        } else if engine.activeStartTimestamp == nil, elapsedSeconds != 0 {
            // The set was dropped back to positioning.
            elapsedSeconds = 0
            startedAt = nil
        }
        if showsGo, timestamp >= goUntil { showsGo = false }

        #if DEBUG
        if wantsDebugStatus { updateDebugStatus(frame: frame, output: output) }
        #endif
    }

    // MARK: Pinned states (screenshots)

    #if DEBUG
    /// Puts the published state into one of the `-debugState` poses.
    private func applyPinned(_ state: AppEnvironment.DebugState) {
        switch state {
        case .positioning:
            phase = .positioning
            isBodyDetected = true
            isPostureValid = false
            holdProgress = 0
        case .shallow:
            phase = .active
            isBodyDetected = true
            isPostureValid = true
            reps = 3
            shallowAttempts = 1
            elapsedSeconds = 24
            depth = 0.52
            ringState = .shallow
            hint = .shallow
        case .finishing:
            phase = .finishing(secondsRemaining: 2.0)
            isBodyDetected = true
            isPostureValid = false
            reps = 6
            elapsedSeconds = 41
        case .nobody:
            phase = .active
            isBodyDetected = false
            reps = 5
            elapsedSeconds = 33
            hint = .noBody
        }
    }

    private func updateDebugStatus(frame: PoseFrame, output: WorkoutSessionEngine.Output) {
        let confident = frame.joints.values.filter { $0.confidence >= 0.3 }.count
        var parts = ["joints \(frame.joints.count) (\(confident) conf)"]
        func number(_ value: Float?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        parts.append("gate \(output.gateFailure?.rawValue ?? "ok")")
        parts.append("torso \(number(output.torsoRatio))")
        parts.append("wrist \(number(output.wristMotionRatio))")
        parts.append("raw \(number(output.rawDepth))")
        parts.append(String(format: "depth %.2f", output.depth))
        parts.append("rejected \(output.rejectedReps)")
        debugStatus = parts.joined(separator: " | ")
    }

    // MARK: Flight recorder

    /// Writes what the workout buffered, once, as the workout ends.
    private func flushFlightLog() {
        guard recordsFlight else { return }
        recordsFlight = false
        let live = LiveResult(
            reps: engine.reps,
            rejectedReps: engine.rejectedReps,
            classifier: CoreMLPoseClassifier.loadFromBundle() == nil ? "heuristic" : "coreml"
        )
        flightRecorder.flush(live: live, config: engine.config, device: Self.deviceInfo())
    }

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
    #endif
}
