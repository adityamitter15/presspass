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

    var text: String {
        switch self {
        case .noBody: "Step back so I can see you"
        case .armsHidden: "I can't see your arms"
        case .handsPosition: "Hands on the floor, under your shoulders"
        case .shallow: "Go lower"
        }
    }

    var systemImage: String {
        switch self {
        case .noBody: "person.fill.questionmark"
        case .armsHidden: "eye.slash.fill"
        case .handsPosition: "hand.raised.fill"
        case .shallow: "arrow.down.to.line"
        }
    }

    var tone: HintPill.Tone {
        switch self {
        case .noBody, .armsHidden: .coral
        case .handsPosition: .neutral
        case .shallow: .amber
        }
    }
}

extension WorkoutFlow.Phase {
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

/// Coordinates the pose source (camera, or a replay in the Simulator), the
/// pipeline, the hands-free `WorkoutFlow` and the display-only `DepthTracker`
/// for one workout, and publishes what `WorkoutView` renders. Everything
/// downstream of the `PoseSource` runs synchronously on the delivery queue's
/// callback, cheap enough per frame, and keeping it on the main queue means
/// the `@Published` updates below don't need an extra hop. All timing uses
/// frame timestamps, so there are no timers to keep in step.
final class WorkoutViewModel: ObservableObject {
    // MARK: Published state

    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var isBodyDetected: Bool = false
    /// The hands are on the floor under the shoulders.
    @Published private(set) var isPostureValid: Bool = false
    /// 0 to 1 over the flow's start hold, while positioning.
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var phase: WorkoutFlow.Phase = .positioning
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
    /// Live pipeline internals for the on-screen debug HUD.
    @Published private(set) var debugStatus: String = ""
    #endif

    /// One minute earned per counted rep.
    var minutesEarned: Int { reps }

    // MARK: Collaborators

    private let poseSource: PoseSource
    private let pipeline: PushupPipeline
    private var flow = WorkoutFlow()
    private var depthTracker = DepthTracker()
    private var audio: WorkoutAudio?

    // MARK: Per-set bookkeeping

    private static let hintHold: TimeInterval = 0.6
    private static let shallowHintSeconds: TimeInterval = 1.2
    private static let shallowRingSeconds: TimeInterval = 1.0
    private static let goSeconds: TimeInterval = 0.9
    private static let startHold = WorkoutFlow.Config.default.startHold

    private var activeStart: TimeInterval?
    private var startedAt: Date?
    private var repTimes: [Double] = []
    private var lastValidTimestamp: TimeInterval = 0
    private var holdStart: TimeInterval?
    private var hintCandidate: WorkoutHint?
    private var hintSince: TimeInterval = 0
    private var shallowHintUntil: TimeInterval = 0
    private var shallowRingUntil: TimeInterval = 0
    private var goUntil: TimeInterval = 0
    private var hasFinished = false
    private var pinnedState: AppEnvironment.DebugState?
    private var wantsDebugStatus = false

    init(
        poseSource: PoseSource = AppEnvironment.current.makePoseSource(),
        pipeline: PushupPipeline = PushupPipeline(classifier: PoseClassifierFactory.makeDefault())
    ) {
        self.poseSource = poseSource
        self.pipeline = pipeline
        self.poseSource.onFrame = { [weak self] frame in
            self?.handle(frame: frame)
        }
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
        pipeline.reset()
        depthTracker.reset()
        flow = WorkoutFlow(config: WorkoutFlow.Config(
            idleBeforeFinishing: AppSettings.autoFinish ? WorkoutFlow.Config.default.idleBeforeFinishing : .infinity
        ))
        audio = WorkoutAudio(mode: AppSettings.soundMode)
        audio?.begin()

        activeStart = nil
        startedAt = nil
        repTimes = []
        lastValidTimestamp = 0
        holdStart = nil
        hintCandidate = nil
        hintSince = 0
        shallowHintUntil = 0
        shallowRingUntil = 0
        goUntil = 0
        hasFinished = false

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
        flow.finishNow()
        phase = flow.phase
    }

    /// Stops the source and returns the record of the set, or nil when no rep
    /// was counted. Plays the finishing phrase when there is a record.
    func finish() -> WorkoutSessionRecord? {
        guard !hasFinished else { return nil }
        hasFinished = true
        flow.finishNow()
        phase = .finished
        let record = makeRecord()
        if record != nil { audio?.finish() }
        stopRunning()
        return record
    }

    private func stopRunning() {
        poseSource.stop()
        audio?.end()
        isRunning = false
    }

    private func makeRecord() -> WorkoutSessionRecord? {
        guard reps > 0 else { return nil }
        let lastRep = repTimes.last ?? 0
        let lastInPosition = activeStart.map { max(0, lastValidTimestamp - $0) } ?? 0
        return WorkoutSessionRecord(
            startedAt: startedAt ?? Date(),
            durationSeconds: max(lastRep, lastInPosition),
            reps: reps,
            repTimes: repTimes,
            shallowAttempts: shallowAttempts,
            minutesEarned: minutesEarned
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

        let repsBefore = reps
        let output = pipeline.process(frame)
        let inPosture = output.postureValid && output.requiredJointsConfident
        let bodyDetected = !frame.joints.isEmpty

        let phaseBefore = flow.phase
        flow.update(postureValid: inPosture, reps: output.reps, timestamp: timestamp)
        let phaseAfter = flow.phase

        if phaseBefore == .positioning, phaseAfter == .active {
            beginSet(at: timestamp)
        } else if phaseBefore == .active, phaseAfter == .positioning {
            activeStart = nil
            startedAt = nil
            if elapsedSeconds != 0 { elapsedSeconds = 0 }
        }
        if phaseAfter != phase { phase = phaseAfter }

        if isBodyDetected != bodyDetected { isBodyDetected = bodyDetected }
        if isPostureValid != output.postureValid { isPostureValid = output.postureValid }

        updateHold(inPosture: inPosture, phase: phaseAfter, timestamp: timestamp)

        if output.reps != reps {
            reps = output.reps
        }
        if output.rejectedReps != rejectedReps { rejectedReps = output.rejectedReps }
        if output.reps > repsBefore { repCounted(total: output.reps, at: timestamp) }

        if output.features != nil {
            if currentLabel != output.currentLabel { currentLabel = output.currentLabel }
            if ignoreReason != output.ignoreReason { ignoreReason = output.ignoreReason }
        }

        let isSetRunning = phaseAfter.isCounting
        if isSetRunning, inPosture { lastValidTimestamp = timestamp }

        let event = depthTracker.update(with: output, repsBefore: repsBefore)
        let newDepth = Double(depthTracker.depth)
        if abs(newDepth - depth) > 0.002 { depth = newDepth }
        if isSetRunning, case .shallowAttempt = event {
            shallowAttempts += 1
            shallowHintUntil = timestamp + Self.shallowHintSeconds
            shallowRingUntil = timestamp + Self.shallowRingSeconds
            audio?.shallowAttempt()
        }

        let ringNow: RingState = timestamp < shallowRingUntil ? .shallow : .tracking
        if ringState != ringNow { ringState = ringNow }

        updateHint(
            bodyDetected: bodyDetected,
            requiredJointsConfident: output.requiredJointsConfident,
            postureValid: output.postureValid,
            phase: phaseAfter,
            timestamp: timestamp
        )

        if let activeStart {
            let seconds = Int(max(0, timestamp - activeStart))
            if seconds != elapsedSeconds { elapsedSeconds = seconds }
        }
        if showsGo, timestamp >= goUntil { showsGo = false }

        #if DEBUG
        if wantsDebugStatus { updateDebugStatus(frame: frame, output: output) }
        #endif
    }

    private func beginSet(at timestamp: TimeInterval) {
        activeStart = timestamp
        startedAt = Date()
        repTimes = []
        lastValidTimestamp = timestamp
        goUntil = timestamp + Self.goSeconds
        showsGo = true
        elapsedSeconds = 0
        holdProgress = 0
        audio?.go()
    }

    private func repCounted(total: Int, at timestamp: TimeInterval) {
        repTimes.append(max(0, timestamp - (activeStart ?? timestamp)))
        audio?.rep(total)
    }

    /// Mirrors the flow's start hold so the positioning ring can fill with it.
    private func updateHold(inPosture: Bool, phase: WorkoutFlow.Phase, timestamp: TimeInterval) {
        var progress = 0.0
        if phase == .positioning, inPosture {
            let since = holdStart ?? timestamp
            holdStart = since
            progress = min((timestamp - since) / Self.startHold, 1)
        } else {
            holdStart = nil
        }
        if abs(progress - holdProgress) > 0.01 || (progress == 0 && holdProgress != 0) {
            holdProgress = progress
        }
    }

    /// A hint shows only once its condition has held for `hintHold` seconds.
    private func updateHint(
        bodyDetected: Bool,
        requiredJointsConfident: Bool,
        postureValid: Bool,
        phase: WorkoutFlow.Phase,
        timestamp: TimeInterval
    ) {
        var candidate: WorkoutHint?
        if !bodyDetected {
            candidate = .noBody
        } else if !requiredJointsConfident {
            candidate = .armsHidden
        } else if !postureValid {
            candidate = .handsPosition
        }
        if candidate != hintCandidate {
            hintCandidate = candidate
            hintSince = timestamp
        }

        var shown: WorkoutHint?
        if phase == .active {
            if timestamp < shallowHintUntil {
                shown = .shallow
            } else if let candidate, timestamp - hintSince >= Self.hintHold {
                shown = candidate
            }
        }
        if hint != shown { hint = shown }
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

    private func updateDebugStatus(frame: PoseFrame, output: PipelineOutput) {
        let confident = frame.joints.values.filter { $0.confidence >= 0.3 }.count
        var parts = ["joints \(frame.joints.count) (\(confident) conf)"]
        if let features = output.features {
            let leftElbow = features[PushupFeatureExtractor.leftElbowAngleIndex] * 180 / .pi
            let rightElbow = features[PushupFeatureExtractor.rightElbowAngleIndex] * 180 / .pi
            parts.append(String(format: "elbow L%.0f R%.0f", leftElbow, rightElbow))
            parts.append("posture \(PostureGate.isPushupPosture(frame.joints) ? "ok" : "BAD")")
            parts.append("label \(output.frameLabel?.rawValue ?? "-")")
        } else {
            parts.append("features: nil (conf gate)")
        }
        parts.append(String(format: "depth %.2f", depthTracker.depth))
        parts.append("rejected \(output.rejectedReps)")
        debugStatus = parts.joined(separator: " | ")
    }
    #endif
}
