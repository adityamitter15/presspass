import CoreGraphics
import Foundation

/// Every tunable threshold of the workout session engine, in one value that
/// can be written to and read from JSON. A missing key decodes to its default.
///
/// Three ideas, each of which can be switched off on its own:
/// - planted hands (`plantedHandsGate`): in a real press-up the hands do not
///   move, in an arm wave they move the most;
/// - horizontal body (`horizontalBodyGate`): filmed head-on from the floor, a
///   body in press-up position is strongly foreshortened, a standing or
///   kneeling body is tall;
/// - starting from a held top position (`startHold`, `startRequiresStraightArms`)
///   and ending the set when a planted hand leaves its place.
///
/// The thresholds are first guesses, to be tuned against real recordings.
public struct SessionConfig: Codable, Equatable {
    /// Rep counter and heuristic thresholds.
    public var pipeline: PipelineConfig
    /// Display depth settings and the elbow thresholds `rawDepth` is measured against.
    public var depth: DepthTracker.Config
    /// Image width divided by image height. Normalized x and y are in
    /// different units for a non-square image, so every image-space distance
    /// multiplies x by this first.
    public var imageAspect: Double

    // Starting
    /// Seconds a valid top position must be held before counting begins.
    public var startHold: Double
    /// When true the start hold only accumulates while the arms are straight.
    public var startRequiresStraightArms: Bool
    /// Largest raw depth (see `DepthTracker`'s formula) that counts as straight arms.
    public var straightArmsMaxDepth: Float

    // Gates applied to every frame once active, and to the start hold
    public var plantedHandsGate: Bool
    /// Seconds of wrist positions the planted-hands measure looks back over.
    public var plantedHandsWindow: Double
    /// Largest `wristMotionRatio` (in shoulder widths) that still counts as planted.
    public var plantedHandsMaxMotion: Float
    public var horizontalBodyGate: Bool
    /// Largest `torsoRatio` (torso length / shoulder width) that still counts as horizontal.
    public var horizontalBodyMaxTorsoRatio: Float

    // Ending
    /// When false the set never ends by itself.
    public var autoFinish: Bool
    /// Shoulder widths a wrist may be from its planted anchor before it counts as left. Only
    /// used when `plantedHandsGate` is on, since the anchors belong to that gate.
    public var leaveHandsMotion: Float
    /// Seconds a wrist must stay beyond `leaveHandsMotion` to end the set.
    public var leaveHold: Double
    /// Seconds of frames that are not a valid planted posture before the set ends.
    public var idleBeforeFinishing: Double
    public var finishingCountdown: Double
    /// Seconds of valid posture that cancel the finishing countdown.
    public var resumeHold: Double
    /// When true a set with zero reps goes back to positioning instead of finishing.
    public var requiresRepToAutoFinish: Bool

    public static let `default` = SessionConfig()

    /// The behaviour before this engine existed: no planted-hands or
    /// horizontal-body gate and no straight-arms requirement. The leave-hands
    /// ending is tied to the planted-hands gate, so it is off here too.
    public static let legacy: SessionConfig = {
        var config = SessionConfig()
        config.plantedHandsGate = false
        config.horizontalBodyGate = false
        config.startRequiresStraightArms = false
        return config
    }()

    public init(
        pipeline: PipelineConfig = .default,
        depth: DepthTracker.Config = .default,
        imageAspect: Double = 9.0 / 16.0,
        startHold: Double = 1.0,
        startRequiresStraightArms: Bool = true,
        straightArmsMaxDepth: Float = 0.2,
        plantedHandsGate: Bool = true,
        plantedHandsWindow: Double = 0.6,
        plantedHandsMaxMotion: Float = 0.35,
        horizontalBodyGate: Bool = true,
        horizontalBodyMaxTorsoRatio: Float = 0.9,
        autoFinish: Bool = true,
        leaveHandsMotion: Float = 0.5,
        leaveHold: Double = 0.3,
        idleBeforeFinishing: Double = 1.0,
        finishingCountdown: Double = 2.0,
        resumeHold: Double = 0.3,
        requiresRepToAutoFinish: Bool = true
    ) {
        self.pipeline = pipeline
        self.depth = depth
        self.imageAspect = imageAspect
        self.startHold = startHold
        self.startRequiresStraightArms = startRequiresStraightArms
        self.straightArmsMaxDepth = straightArmsMaxDepth
        self.plantedHandsGate = plantedHandsGate
        self.plantedHandsWindow = plantedHandsWindow
        self.plantedHandsMaxMotion = plantedHandsMaxMotion
        self.horizontalBodyGate = horizontalBodyGate
        self.horizontalBodyMaxTorsoRatio = horizontalBodyMaxTorsoRatio
        self.autoFinish = autoFinish
        self.leaveHandsMotion = leaveHandsMotion
        self.leaveHold = leaveHold
        self.idleBeforeFinishing = idleBeforeFinishing
        self.finishingCountdown = finishingCountdown
        self.resumeHold = resumeHold
        self.requiresRepToAutoFinish = requiresRepToAutoFinish
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SessionConfig()
        self.init(
            pipeline: try c.decodeIfPresent(PipelineConfig.self, forKey: .pipeline) ?? d.pipeline,
            depth: try c.decodeIfPresent(DepthTracker.Config.self, forKey: .depth) ?? d.depth,
            imageAspect: try c.decodeIfPresent(Double.self, forKey: .imageAspect) ?? d.imageAspect,
            startHold: try c.decodeIfPresent(Double.self, forKey: .startHold) ?? d.startHold,
            startRequiresStraightArms: try c.decodeIfPresent(Bool.self, forKey: .startRequiresStraightArms) ?? d.startRequiresStraightArms,
            straightArmsMaxDepth: try c.decodeIfPresent(Float.self, forKey: .straightArmsMaxDepth) ?? d.straightArmsMaxDepth,
            plantedHandsGate: try c.decodeIfPresent(Bool.self, forKey: .plantedHandsGate) ?? d.plantedHandsGate,
            plantedHandsWindow: try c.decodeIfPresent(Double.self, forKey: .plantedHandsWindow) ?? d.plantedHandsWindow,
            plantedHandsMaxMotion: try c.decodeIfPresent(Float.self, forKey: .plantedHandsMaxMotion) ?? d.plantedHandsMaxMotion,
            horizontalBodyGate: try c.decodeIfPresent(Bool.self, forKey: .horizontalBodyGate) ?? d.horizontalBodyGate,
            horizontalBodyMaxTorsoRatio: try c.decodeIfPresent(Float.self, forKey: .horizontalBodyMaxTorsoRatio) ?? d.horizontalBodyMaxTorsoRatio,
            autoFinish: try c.decodeIfPresent(Bool.self, forKey: .autoFinish) ?? d.autoFinish,
            leaveHandsMotion: try c.decodeIfPresent(Float.self, forKey: .leaveHandsMotion) ?? d.leaveHandsMotion,
            leaveHold: try c.decodeIfPresent(Double.self, forKey: .leaveHold) ?? d.leaveHold,
            idleBeforeFinishing: try c.decodeIfPresent(Double.self, forKey: .idleBeforeFinishing) ?? d.idleBeforeFinishing,
            finishingCountdown: try c.decodeIfPresent(Double.self, forKey: .finishingCountdown) ?? d.finishingCountdown,
            resumeHold: try c.decodeIfPresent(Double.self, forKey: .resumeHold) ?? d.resumeHold,
            requiresRepToAutoFinish: try c.decodeIfPresent(Bool.self, forKey: .requiresRepToAutoFinish) ?? d.requiresRepToAutoFinish
        )
    }

    /// Human-readable `key = value` lines for every value that differs from
    /// `SessionConfig.default`, in a fixed order. Empty when the config is the default.
    public var nonDefaultDescription: [String] {
        let d = SessionConfig()
        var lines: [String] = []
        if pipeline != d.pipeline { lines.append("pipeline = non-default") }
        if depth != d.depth { lines.append("depth = non-default") }
        func add<T: Equatable>(_ name: String, _ value: T, _ other: T) {
            if value != other { lines.append("\(name) = \(value)") }
        }
        add("imageAspect", imageAspect, d.imageAspect)
        add("startHold", startHold, d.startHold)
        add("startRequiresStraightArms", startRequiresStraightArms, d.startRequiresStraightArms)
        add("straightArmsMaxDepth", straightArmsMaxDepth, d.straightArmsMaxDepth)
        add("plantedHandsGate", plantedHandsGate, d.plantedHandsGate)
        add("plantedHandsWindow", plantedHandsWindow, d.plantedHandsWindow)
        add("plantedHandsMaxMotion", plantedHandsMaxMotion, d.plantedHandsMaxMotion)
        add("horizontalBodyGate", horizontalBodyGate, d.horizontalBodyGate)
        add("horizontalBodyMaxTorsoRatio", horizontalBodyMaxTorsoRatio, d.horizontalBodyMaxTorsoRatio)
        add("autoFinish", autoFinish, d.autoFinish)
        add("leaveHandsMotion", leaveHandsMotion, d.leaveHandsMotion)
        add("leaveHold", leaveHold, d.leaveHold)
        add("idleBeforeFinishing", idleBeforeFinishing, d.idleBeforeFinishing)
        add("finishingCountdown", finishingCountdown, d.finishingCountdown)
        add("resumeHold", resumeHold, d.resumeHold)
        add("requiresRepToAutoFinish", requiresRepToAutoFinish, d.requiresRepToAutoFinish)
        return lines
    }
}

/// The whole hands-free workout, as one deterministic engine driven by pose
/// frames: wait for a held top position, count, and end the set when the
/// person leaves. Both the app and the offline evaluation tool run this
/// class, so a benchmark measures what ships. All timing uses frame
/// timestamps, there are no timers.
///
/// Image-space measures use isotropic coordinates: a point `(x, y)` is
/// measured as `(x * imageAspect, y)`.
///
/// - shoulder width = distance between the two shoulders;
/// - torso length = distance between the shoulder midpoint and the hip midpoint;
/// - `torsoRatio` = torso length / shoulder width;
/// - `wristMotionRatio` = over the last `plantedHandsWindow` seconds, for each
///   wrist the largest distance between a sample and the window's median
///   position (median of x and of y separately), the larger of the two
///   wrists, divided by the median shoulder width of the window;
/// - `rawDepth` = `clamp((up - meanElbowDegrees) / max(up - down, 1), 0, 1)` with
///   `up` and `down` from `SessionConfig.depth`, the formula of `DepthTracker`.
public final class WorkoutSessionEngine {
    public enum Phase: Equatable {
        case positioning
        case active
        case finishing(secondsRemaining: Double)
        case finished
    }

    public enum GateFailure: String, Codable, CaseIterable {
        case noBody, lowConfidence, notInPosture, notHorizontal, handsMoving
    }

    public enum Hint: Equatable {
        case stepBack, cannotSeeArms, handsOnFloor, holdTheTop, goLower
    }

    public enum Event: Equatable {
        case started
        case repCounted(Int)
        case shallowAttempt(peakDepth: Float)
        case finishingBegan
        case resumed
        case finished
    }

    public struct Output {
        public let phase: Phase
        public let reps: Int
        /// Smoothed display depth, 0 to 1.
        public let depth: Float
        /// 0 to 1 during positioning.
        public let holdProgress: Double
        public let hint: Hint?
        /// What happened on this frame.
        public let events: [Event]
        public let shallowAttempts: Int
        public let rejectedReps: Int
        // Per-frame diagnostics, for analysis and tuning.
        /// First failing check on this frame, nil if the frame is a valid planted posture.
        public let gateFailure: GateFailure?
        /// Nil when it cannot be computed.
        public let wristMotionRatio: Float?
        public let torsoRatio: Float?
        public let rawDepth: Float?
        /// Nil when the frame was not fed to the counter.
        public let pipeline: PipelineOutput?
    }

    // MARK: Constants

    private static let eps = 1e-6
    private static let minWindowSpan = 0.3
    private static let anchorFollow = 0.02
    private static let hintHold = 0.6
    private static let shallowHintSeconds = 1.2

    // MARK: State

    public private(set) var config: SessionConfig
    private let classifier: PoseClassifier?

    public private(set) var phase: Phase = .positioning
    public private(set) var reps = 0
    public private(set) var rejectedReps = 0
    public private(set) var shallowAttempts = 0
    /// Frame timestamps at which reps were counted in the current session.
    public private(set) var repTimes: [TimeInterval] = []
    /// Timestamp of the frame at which the current session began counting;
    /// kept after the set finishes, nil while positioning.
    public private(set) var activeStartTimestamp: TimeInterval?
    /// Timestamp of the latest valid frame while the set was running.
    public private(set) var lastValidTimestamp: TimeInterval?
    /// Last pipeline output of the current session (label, ignore reason), nil before the first.
    public private(set) var lastPipelineOutput: PipelineOutput?

    private var pipeline: PushupPipeline?
    private var depthTracker: DepthTracker

    private struct WristSample {
        var t: TimeInterval
        var left: CGPoint
        var right: CGPoint
        var shoulderWidth: Double
    }
    private var window: [WristSample] = []
    private var lastTimestamp: TimeInterval?

    private var holdSince: TimeInterval?
    private var holdProgress = 0.0
    private var invalidSince: TimeInterval?
    private var leaveSince: TimeInterval?
    private var resumeSince: TimeInterval?
    private var countdownStart: TimeInterval = 0
    private var anchorLeft: CGPoint?
    private var anchorRight: CGPoint?
    private var pendingFinishedEvent = false

    private var hintCandidate: Hint?
    private var hintSince: TimeInterval = 0
    private var shallowHintUntil: TimeInterval = 0

    public init(config: SessionConfig = .default, classifier: PoseClassifier? = nil) {
        self.config = config
        self.classifier = classifier
        self.depthTracker = DepthTracker(config: config.depth)
    }

    public func reset() {
        phase = .positioning
        reps = 0
        rejectedReps = 0
        shallowAttempts = 0
        repTimes = []
        activeStartTimestamp = nil
        lastValidTimestamp = nil
        lastPipelineOutput = nil
        pipeline = nil
        depthTracker = DepthTracker(config: config.depth)
        window = []
        lastTimestamp = nil
        holdSince = nil
        holdProgress = 0
        invalidSince = nil
        leaveSince = nil
        resumeSince = nil
        countdownStart = 0
        anchorLeft = nil
        anchorRight = nil
        pendingFinishedEvent = false
        hintCandidate = nil
        hintSince = 0
        shallowHintUntil = 0
    }

    /// Ends the set from any other phase. The next `process` call reports
    /// `.finished` once. A no-op when already finished.
    public func finishNow() {
        guard phase != .finished else { return }
        phase = .finished
        pendingFinishedEvent = true
        holdProgress = 0
    }

    // MARK: Frames

    @discardableResult
    public func process(_ frame: PoseFrame) -> Output {
        let t = frame.timestamp
        if let last = lastTimestamp, t < last { window.removeAll() }
        lastTimestamp = t

        let torso = Self.torsoRatio(frame.joints, aspect: config.imageAspect)
        let wrist = updateWristWindow(frame, at: t)
        let features = PushupFeatureExtractor.extract(frame.joints)
        let raw = rawDepth(features)
        let gate = gateFailure(frame, torsoRatio: torso, wristMotion: wrist)
        let armsStraight = !config.startRequiresStraightArms || (raw.map { $0 <= config.straightArmsMaxDepth } ?? false)

        var events: [Event] = []
        if pendingFinishedEvent {
            events.append(.finished)
            pendingFinishedEvent = false
        }
        var fed: PipelineOutput?

        switch phase {
        case .positioning:
            stepPositioning(gate: gate, armsStraight: armsStraight, frame: frame, events: &events)
        case .active:
            fed = stepActive(gate: gate, frame: frame, events: &events)
        case .finishing:
            stepFinishing(gate: gate, frame: frame, events: &events)
        case .finished:
            break
        }

        let hint = updateHint(gate: gate, armsStraight: armsStraight, at: t)
        return Output(
            phase: phase,
            reps: reps,
            depth: depthTracker.depth,
            holdProgress: phase == .positioning ? holdProgress : 0,
            hint: hint,
            events: events,
            shallowAttempts: shallowAttempts,
            rejectedReps: rejectedReps,
            gateFailure: gate,
            wristMotionRatio: wrist,
            torsoRatio: torso,
            rawDepth: raw,
            pipeline: fed
        )
    }

    // MARK: Phases

    private func stepPositioning(gate: GateFailure?, armsStraight: Bool, frame: PoseFrame, events: inout [Event]) {
        let t = frame.timestamp
        guard gate == nil, armsStraight else {
            holdSince = nil
            holdProgress = 0
            return
        }
        let since = holdSince ?? t
        holdSince = since
        let elapsed = t - since
        holdProgress = config.startHold > 0 ? min(max(elapsed / config.startHold, 0), 1) : 1
        guard elapsed >= config.startHold - Self.eps else { return }
        begin(at: t, frame: frame)
        events.append(.started)
    }

    private func begin(at t: TimeInterval, frame: PoseFrame) {
        pipeline = config.pipeline.makePipeline(classifier: classifier)
        depthTracker = DepthTracker(config: config.depth)
        repTimes = []
        reps = 0
        rejectedReps = 0
        shallowAttempts = 0
        lastPipelineOutput = nil
        activeStartTimestamp = t
        lastValidTimestamp = t
        invalidSince = nil
        leaveSince = nil
        resumeSince = nil
        holdSince = nil
        holdProgress = 0
        shallowHintUntil = 0
        anchor(frame)
        phase = .active
        resetHintTracking()
    }

    private func stepActive(gate: GateFailure?, frame: PoseFrame, events: inout [Event]) -> PipelineOutput? {
        let t = frame.timestamp
        var fed: PipelineOutput?

        if gate == nil, let pipeline {
            invalidSince = nil
            lastValidTimestamp = t
            let before = reps
            let output = pipeline.process(frame)
            fed = output
            lastPipelineOutput = output
            reps = output.reps
            rejectedReps = output.rejectedReps
            if output.reps > before {
                for number in (before + 1)...output.reps {
                    repTimes.append(t)
                    events.append(.repCounted(number))
                }
            }
            if case .shallowAttempt(let peak) = depthTracker.update(with: output, repsBefore: before) {
                shallowAttempts += 1
                shallowHintUntil = t + Self.shallowHintSeconds
                events.append(.shallowAttempt(peakDepth: peak))
            }
        } else {
            invalidSince = invalidSince ?? t
            decayDepth()
        }

        guard config.autoFinish else { return fed }

        var leaving = false
        if config.plantedHandsGate {
            leaving = checkLeave(frame)
            if gate == nil, !isBeyondLeave(frame) { followAnchors(frame) }
        }

        var shouldEnd = leaving
        if let since = invalidSince, t - since >= config.idleBeforeFinishing - Self.eps { shouldEnd = true }
        guard shouldEnd else { return fed }

        if reps > 0 || !config.requiresRepToAutoFinish {
            phase = .finishing(secondsRemaining: config.finishingCountdown)
            countdownStart = t
            resumeSince = nil
            events.append(.finishingBegan)
        } else {
            phase = .positioning
            holdSince = nil
            holdProgress = 0
            activeStartTimestamp = nil
            lastValidTimestamp = nil
            invalidSince = nil
            leaveSince = nil
        }
        resetHintTracking()
        return fed
    }

    private func stepFinishing(gate: GateFailure?, frame: PoseFrame, events: inout [Event]) {
        let t = frame.timestamp
        decayDepth()
        let remaining = config.finishingCountdown - (t - countdownStart)
        if remaining <= Self.eps {
            phase = .finished
            events.append(.finished)
            resetHintTracking()
            return
        }
        phase = .finishing(secondsRemaining: remaining)
        guard gate == nil else {
            resumeSince = nil
            return
        }
        let since = resumeSince ?? t
        resumeSince = since
        guard t - since >= config.resumeHold - Self.eps else { return }
        phase = .active
        invalidSince = nil
        leaveSince = nil
        resumeSince = nil
        lastValidTimestamp = t
        anchor(frame)
        events.append(.resumed)
        resetHintTracking()
    }

    /// A frame that is not fed to the counter pulls the display depth to 0.
    private func decayDepth() {
        let stub = PipelineOutput(
            reps: reps,
            rejectedReps: rejectedReps,
            phase: lastPipelineOutput?.phase ?? .idle,
            currentLabel: lastPipelineOutput?.currentLabel ?? .notPushup,
            ignoreReason: .none,
            features: nil,
            frameLabel: nil,
            frameConfidence: nil,
            postureValid: false,
            requiredJointsConfident: false
        )
        _ = depthTracker.update(with: stub, repsBefore: reps)
    }

    // MARK: Gates

    private func gateFailure(_ frame: PoseFrame, torsoRatio: Float?, wristMotion: Float?) -> GateFailure? {
        if frame.joints.isEmpty { return .noBody }
        if !PostureGate.requiredJointsConfident(frame.joints) { return .lowConfidence }
        if !PostureGate.isPushupPosture(frame.joints) { return .notInPosture }
        if config.horizontalBodyGate {
            guard let ratio = torsoRatio, ratio <= config.horizontalBodyMaxTorsoRatio else { return .notHorizontal }
        }
        if config.plantedHandsGate, let motion = wristMotion, motion > config.plantedHandsMaxMotion {
            return .handsMoving
        }
        return nil
    }

    private func rawDepth(_ features: [Float]?) -> Float? {
        guard let features, features.count == PushupFeatureExtractor.featureDim else { return nil }
        let left = features[PushupFeatureExtractor.leftElbowAngleIndex] * 180 / .pi
        let right = features[PushupFeatureExtractor.rightElbowAngleIndex] * 180 / .pi
        let mean = (left + right) / 2
        let span = max(config.depth.upElbowDegrees - config.depth.downElbowDegrees, 1)
        return min(max((config.depth.upElbowDegrees - mean) / span, 0), 1)
    }

    // MARK: Geometry

    private func iso(_ point: JointPoint) -> CGPoint {
        CGPoint(x: point.x * CGFloat(config.imageAspect), y: point.y)
    }

    /// Torso length divided by shoulder width, nil when a needed joint is
    /// missing or the shoulders coincide.
    public static func torsoRatio(_ joints: [JointName: JointPoint], aspect: Double) -> Float? {
        guard let ls = joints[.leftShoulder], let rs = joints[.rightShoulder],
              let lh = joints[.leftHip], let rh = joints[.rightHip] else { return nil }
        let a = CGFloat(aspect)
        let shoulderWidth = hypot((ls.x - rs.x) * a, ls.y - rs.y)
        guard shoulderWidth > 1e-4 else { return nil }
        let sx = (ls.x + rs.x) / 2 * a, sy = (ls.y + rs.y) / 2
        let hx = (lh.x + rh.x) / 2 * a, hy = (lh.y + rh.y) / 2
        return Float(hypot(sx - hx, sy - hy) / shoulderWidth)
    }

    private func shoulderWidth(_ joints: [JointName: JointPoint]) -> Double? {
        guard let ls = joints[.leftShoulder], let rs = joints[.rightShoulder] else { return nil }
        let width = hypot(iso(ls).x - iso(rs).x, iso(ls).y - iso(rs).y)
        return width > 1e-4 ? Double(width) : nil
    }

    private func updateWristWindow(_ frame: PoseFrame, at t: TimeInterval) -> Float? {
        guard let lw = frame.joints[.leftWrist], let rw = frame.joints[.rightWrist],
              let width = shoulderWidth(frame.joints) else { return nil }
        window.append(WristSample(t: t, left: iso(lw), right: iso(rw), shoulderWidth: width))
        let oldest = t - config.plantedHandsWindow - Self.eps
        window.removeAll { $0.t < oldest }
        guard let first = window.first, t - first.t >= Self.minWindowSpan - Self.eps else { return nil }

        func spread(_ points: [CGPoint]) -> Double {
            let mx = Self.median(points.map { Double($0.x) })
            let my = Self.median(points.map { Double($0.y) })
            return points.map { hypot(Double($0.x) - mx, Double($0.y) - my) }.max() ?? 0
        }
        let worst = max(spread(window.map(\.left)), spread(window.map(\.right)))
        let width2 = Self.median(window.map(\.shoulderWidth))
        guard width2 > 0 else { return nil }
        return Float(worst / width2)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: Anchors

    private func anchor(_ frame: PoseFrame) {
        guard let lw = frame.joints[.leftWrist], let rw = frame.joints[.rightWrist] else { return }
        anchorLeft = iso(lw)
        anchorRight = iso(rw)
    }

    private func followAnchors(_ frame: PoseFrame) {
        guard let lw = frame.joints[.leftWrist], let rw = frame.joints[.rightWrist],
              let al = anchorLeft, let ar = anchorRight else { return }
        let k = CGFloat(Self.anchorFollow)
        let l = iso(lw), r = iso(rw)
        anchorLeft = CGPoint(x: al.x + k * (l.x - al.x), y: al.y + k * (l.y - al.y))
        anchorRight = CGPoint(x: ar.x + k * (r.x - ar.x), y: ar.y + k * (r.y - ar.y))
    }

    /// Whether either wrist is further than `leaveHandsMotion` shoulder
    /// widths from its anchor on this frame. Nil-safe: false when it cannot be measured.
    private func isBeyondLeave(_ frame: PoseFrame) -> Bool {
        guard let lw = frame.joints[.leftWrist], let rw = frame.joints[.rightWrist],
              let al = anchorLeft, let ar = anchorRight,
              let width = shoulderWidth(frame.joints) else { return false }
        let l = iso(lw), r = iso(rw)
        let dl = Double(hypot(l.x - al.x, l.y - al.y)) / width
        let dr = Double(hypot(r.x - ar.x, r.y - ar.y)) / width
        return Float(max(dl, dr)) > config.leaveHandsMotion
    }

    /// Tracks how long a wrist has been away from its anchor; true once that
    /// has lasted `leaveHold`. Frames where the wrists cannot be measured leave the timer alone.
    private func checkLeave(_ frame: PoseFrame) -> Bool {
        guard frame.joints[.leftWrist] != nil, frame.joints[.rightWrist] != nil,
              anchorLeft != nil, shoulderWidth(frame.joints) != nil else { return false }
        if isBeyondLeave(frame) {
            let since = leaveSince ?? frame.timestamp
            leaveSince = since
            return frame.timestamp - since >= config.leaveHold - Self.eps
        }
        leaveSince = nil
        return false
    }

    // MARK: Hints

    private func resetHintTracking() {
        hintCandidate = nil
        hintSince = lastTimestamp ?? 0
    }

    private func updateHint(gate: GateFailure?, armsStraight: Bool, at t: TimeInterval) -> Hint? {
        switch phase {
        case .finishing, .finished:
            hintCandidate = nil
            return nil
        case .positioning, .active:
            break
        }
        var candidate: Hint?
        switch gate {
        case .noBody: candidate = .stepBack
        case .lowConfidence: candidate = .cannotSeeArms
        case .notInPosture, .notHorizontal, .handsMoving: candidate = .handsOnFloor
        case nil:
            if phase == .positioning, !armsStraight { candidate = .holdTheTop }
        }
        if candidate != hintCandidate {
            hintCandidate = candidate
            hintSince = t
        }
        if phase == .active, t < shallowHintUntil { return .goLower }
        if let candidate, t - hintSince >= Self.hintHold - Self.eps { return candidate }
        return nil
    }
}
