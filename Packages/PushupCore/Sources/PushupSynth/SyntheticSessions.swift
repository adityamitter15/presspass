import CoreGraphics
import Foundation
import PushupCore

/// Complete `RecordedSession` values built from `SyntheticPose`, so the
/// evaluation harness can be exercised end to end before any real recording
/// exists. Every session carries the subject `SYN` and the note `synthetic`,
/// which the report keys off to label its numbers as harness output only.
///
/// `seed` drives the take id and a small per-joint position and confidence
/// jitter, so the same seed always gives the same session.
public enum SyntheticSessions {
    public static let subject = "SYN"
    public static let notes = "synthetic"
    public static let fps: Double = 30

    /// Elbow angle at the bottom of a half rep: bent, but never past the
    /// heuristic's "down" threshold.
    public static let halfRepBottomDegrees: Double = 135

    /// 2026-01-10T10:00:00Z, the default recording time.
    public static let defaultCreatedAt = Date(timeIntervalSince1970: 1_768_039_200)

    /// The recording conditions that are not the tempo or the cheat.
    public struct Conditions: Equatable {
        public var lighting: RecordedSession.Tags.Lighting
        public var distance: RecordedSession.Tags.Distance
        public var clothing: RecordedSession.Tags.Clothing
        public var variant: RecordedSession.Tags.Variant

        public init(
            lighting: RecordedSession.Tags.Lighting = .indoorBright,
            distance: RecordedSession.Tags.Distance = .mid,
            clothing: RecordedSession.Tags.Clothing = .fitted,
            variant: RecordedSession.Tags.Variant = .standard
        ) {
            self.lighting = lighting
            self.distance = distance
            self.clothing = clothing
            self.variant = variant
        }
    }

    /// Seconds per rep for each tempo tag.
    public static func secondsPerRep(for tempo: RecordedSession.Tags.Tempo) -> Double {
        switch tempo {
        case .slow: return 4.0
        case .normal, .na: return 2.0
        case .fast: return 1.5
        }
    }

    /// Full-range reps, `trueReps == reps`. `noBodySeconds` blanks the first
    /// frames, as if the person were still getting into position.
    public static func cleanSet(
        reps: Int,
        tempo: RecordedSession.Tags.Tempo = .normal,
        conditions: Conditions = Conditions(),
        createdAt: Date = defaultCreatedAt,
        seed: UInt64 = 1,
        noBodySeconds: Double = 0
    ) -> RecordedSession {
        let poses = SyntheticPose.repSequence(reps: reps, secondsPerRep: secondsPerRep(for: tempo), fps: fps)
        return build(
            kind: .set, trueReps: reps,
            tags: tags(conditions, tempo: tempo, cheat: .none),
            createdAt: createdAt, seed: seed, poses: poses,
            noBody: noBodySeconds > 0 ? 0...noBodySeconds : nil
        )
    }

    /// Reps that never bend past `halfRepBottomDegrees`, `trueReps == 0`.
    public static func halfRepSet(
        reps: Int = 6,
        conditions: Conditions = Conditions(),
        createdAt: Date = defaultCreatedAt,
        seed: UInt64 = 1
    ) -> RecordedSession {
        let poses = SyntheticPose.repSequence(
            reps: reps, secondsPerRep: secondsPerRep(for: .normal), fps: fps,
            bottomDegrees: halfRepBottomDegrees
        )
        return build(
            kind: .set, trueReps: 0,
            tags: tags(conditions, tempo: .normal, cheat: .halfReps),
            createdAt: createdAt, seed: seed, poses: poses, noBody: nil
        )
    }

    /// Full-range arm movement with the wrists above the shoulders, as in a
    /// standing arm wave, `trueReps == 0`.
    public static func armWaveSet(
        reps: Int = 6,
        conditions: Conditions = Conditions(),
        createdAt: Date = defaultCreatedAt,
        seed: UInt64 = 1
    ) -> RecordedSession {
        var options = SyntheticPose.Options()
        options.wristsAboveShoulders = true
        let poses = SyntheticPose.repSequence(
            reps: reps, secondsPerRep: secondsPerRep(for: .normal), fps: fps, options
        )
        return build(
            kind: .set, trueReps: 0,
            tags: tags(conditions, tempo: .normal, cheat: .armWave),
            createdAt: createdAt, seed: seed, poses: poses, noBody: nil
        )
    }

    /// A held plank with no movement, and the person briefly out of frame
    /// during `noBody`. `kind == .negative`, `trueReps == 0`.
    public static func negativeClip(
        seconds: Double = 20,
        conditions: Conditions = Conditions(),
        createdAt: Date = defaultCreatedAt,
        seed: UInt64 = 1,
        noBody: ClosedRange<Double>? = 6...8
    ) -> RecordedSession {
        let poses = SyntheticPose.repSequence(
            reps: 0, secondsPerRep: secondsPerRep(for: .normal), fps: fps,
            leadInSeconds: seconds, leadOutSeconds: 0
        )
        var tags = tags(conditions, tempo: .na, cheat: .none)
        tags.variant = .na
        return build(
            kind: .negative, trueReps: 0, tags: tags,
            createdAt: createdAt, seed: seed, poses: poses, noBody: noBody
        )
    }

    /// `validReps` full reps followed by `halfReps` half reps, `trueReps ==
    /// validReps`, cheat tag `half_reps`.
    public static func mixedSet(
        validReps: Int,
        halfReps: Int,
        tempo: RecordedSession.Tags.Tempo = .normal,
        conditions: Conditions = Conditions(),
        createdAt: Date = defaultCreatedAt,
        seed: UInt64 = 1
    ) -> RecordedSession {
        let pace = secondsPerRep(for: tempo)
        let valid = SyntheticPose.repSequence(reps: validReps, secondsPerRep: pace, fps: fps)
        let half = SyntheticPose.repSequence(
            reps: halfReps, secondsPerRep: pace, fps: fps,
            bottomDegrees: halfRepBottomDegrees,
            leadInSeconds: 0,
            startTime: Double(valid.count) / fps
        )
        return build(
            kind: .set, trueReps: validReps,
            tags: tags(conditions, tempo: tempo, cheat: .halfReps),
            createdAt: createdAt, seed: seed, poses: valid + half, noBody: nil
        )
    }

    // MARK: - Assembly

    private static func tags(
        _ conditions: Conditions,
        tempo: RecordedSession.Tags.Tempo,
        cheat: RecordedSession.Tags.Cheat
    ) -> RecordedSession.Tags {
        RecordedSession.Tags(
            lighting: conditions.lighting,
            distance: conditions.distance,
            clothing: conditions.clothing,
            tempo: tempo,
            variant: conditions.variant,
            cheat: cheat
        )
    }

    private static func build(
        kind: RecordedSession.Kind,
        trueReps: Int,
        tags: RecordedSession.Tags,
        createdAt: Date,
        seed: UInt64,
        poses: [PoseFrame],
        noBody: ClosedRange<Double>?
    ) -> RecordedSession {
        var generator = SeededGenerator(seed: seed)
        let id = uuidString(&generator)
        let noisy = poses.map { jittered($0, &generator) }

        // Same construction the recorder uses: raw frames, then the compact
        // on-disk form relative to the first frame.
        var raw = SyntheticPose.rawFrames(from: noisy)
        if let noBody {
            raw = raw.map { frame in
                guard noBody.contains(frame.timestamp) else { return frame }
                return RawPoseFrame(
                    timestamp: frame.timestamp,
                    presentationTime: frame.presentationTime,
                    landmarks: nil,
                    worldLandmarks: nil
                )
            }
        }
        let originTime = raw.first?.timestamp ?? 0
        let originPresentation = raw.first?.presentationTime
        let frames = raw.map {
            RecordedFrame(raw: $0, originTimestamp: originTime, originPresentationTime: originPresentation)
        }

        var session = RecordedSession(
            id: id,
            createdAt: RecordedSession.iso8601String(from: createdAt),
            kind: kind,
            trueReps: trueReps,
            poseLabel: nil,
            subject: subject,
            tags: tags,
            notes: notes,
            device: DeviceInfo(
                model: "synthetic",
                systemVersion: "0",
                appVersion: "0",
                appBuild: "0",
                poseModel: "synthetic",
                cameraPosition: "front",
                featureVersion: PushupFeatureExtractor.featureVersion
            ),
            live: nil,
            frames: frames
        )
        // What the app would have shown live, so the replay fidelity check
        // has something to compare against.
        let pipeline = PipelineConfig.default.makePipeline()
        var last: PipelineOutput?
        for frame in session.poseFrames() { last = pipeline.process(frame) }
        session.live = LiveResult(reps: last?.reps ?? 0, rejectedReps: last?.rejectedReps ?? 0, classifier: "heuristic")
        return session
    }

    /// Small position and confidence noise. Joints are visited in enum order,
    /// not dictionary order, so the draw sequence is the same on every run.
    private static func jittered(_ frame: PoseFrame, _ generator: inout SeededGenerator) -> PoseFrame {
        var joints: [JointName: JointPoint] = [:]
        for name in JointName.allCases {
            guard let point = frame.joints[name] else { continue }
            let dx = CGFloat(Double.random(in: -0.002...0.002, using: &generator))
            let dy = CGFloat(Double.random(in: -0.002...0.002, using: &generator))
            let dc = Float.random(in: -0.05...0.05, using: &generator)
            joints[name] = JointPoint(x: point.x + dx, y: point.y + dy, confidence: min(max(point.confidence + dc, 0), 1))
        }
        return PoseFrame(timestamp: frame.timestamp, joints: joints)
    }

    private static func uuidString(_ generator: inout SeededGenerator) -> String {
        let high = generator.next()
        let low = generator.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> (8 * UInt64(index)))
            bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (8 * UInt64(index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress) as UUID
        }
        return uuid.uuidString
    }
}

/// SplitMix64: tiny, deterministic and identical on every platform, unlike
/// the system generator.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
