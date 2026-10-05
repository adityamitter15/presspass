import Foundation

/// One recorded take in the evaluation dataset, schema version 2: the raw
/// pose landmark stream plus a human-entered ground truth and condition
/// tags. Field names are the on-disk contract, see `docs/data-format.md`.
public struct RecordedSession: Codable, Equatable {
    public static let currentSchema = 2

    public enum Kind: String, Codable, CaseIterable {
        case set
        case negative
        case pose
    }

    /// Recording conditions. Raw values are the on-disk strings.
    public struct Tags: Codable, Equatable {
        public enum Lighting: String, Codable, CaseIterable {
            case daylight
            case indoorBright = "indoor_bright"
            case dim
        }

        public enum Distance: String, Codable, CaseIterable {
            case near
            case mid
            case far
        }

        public enum Clothing: String, Codable, CaseIterable {
            case fitted
            case loose
        }

        public enum Tempo: String, Codable, CaseIterable {
            case slow
            case normal
            case fast
            case na
        }

        public enum Variant: String, Codable, CaseIterable {
            case standard
            case knuckle
            case knee
            case wide
            case narrow
            case na
        }

        public enum Cheat: String, Codable, CaseIterable {
            case none
            case halfReps = "half_reps"
            case armWave = "arm_wave"
            case phoneMoved = "phone_moved"
            case videoReplay = "video_replay"
            case other
        }

        public var lighting: Lighting
        public var distance: Distance
        public var clothing: Clothing
        public var tempo: Tempo
        public var variant: Variant
        public var cheat: Cheat

        public init(
            lighting: Lighting,
            distance: Distance,
            clothing: Clothing,
            tempo: Tempo,
            variant: Variant,
            cheat: Cheat
        ) {
            self.lighting = lighting
            self.distance = distance
            self.clothing = clothing
            self.tempo = tempo
            self.variant = variant
            self.cheat = cheat
        }
    }

    /// Always `currentSchema` when written.
    public var schema: Int
    /// UUID string.
    public var id: String
    /// ISO 8601, UTC.
    public var createdAt: String
    public var kind: Kind
    /// Human-entered count of valid reps: 0 for a negative, nil for a held pose.
    public var trueReps: Int?
    /// Held-pose kind only.
    public var poseLabel: PoseLabel?
    /// Anonymous subject id such as "S01".
    public var subject: String
    public var tags: Tags
    public var notes: String
    public var device: DeviceInfo
    /// What the app counted live while recording. Hidden from the person
    /// while they entered `trueReps`.
    public var live: LiveResult?
    public var frames: [RecordedFrame]
    /// The phone's own motion during the take, on the same timeline as
    /// `frames[].pts`. nil when it was not recorded (early files, or a device
    /// without motion sensors).
    public var motion: MotionStream?
    /// The camera video of the take, when one was saved. The video file is
    /// stored next to this JSON file, is never part of the published dataset
    /// and is described by `VideoInfo`. nil when no video was saved (early
    /// files, takes recorded with video switched off, simulator).
    public var video: VideoInfo?
    /// True when the app's own live count was shown on screen while this take
    /// was recorded, false for a blind take. nil in files written before the
    /// recorder could show it (the count was always hidden then). Omitted from
    /// the JSON when nil.
    public var countVisible: Bool?
    /// ISO 8601 UTC time of the last manual edit of the labels (true count,
    /// subject, tags, notes). nil when the file has never been edited. Omitted
    /// from the JSON when nil.
    public var editedAt: String?

    public init(
        schema: Int = RecordedSession.currentSchema,
        id: String,
        createdAt: String,
        kind: Kind,
        trueReps: Int?,
        poseLabel: PoseLabel?,
        subject: String,
        tags: Tags,
        notes: String,
        device: DeviceInfo,
        live: LiveResult?,
        frames: [RecordedFrame],
        motion: MotionStream? = nil,
        video: VideoInfo? = nil,
        countVisible: Bool? = nil,
        editedAt: String? = nil
    ) {
        self.schema = schema
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.trueReps = trueReps
        self.poseLabel = poseLabel
        self.subject = subject
        self.tags = tags
        self.notes = notes
        self.device = device
        self.live = live
        self.frames = frames
        self.motion = motion
        self.video = video
        self.countVisible = countVisible
        self.editedAt = editedAt
    }
}

/// The video file saved next to a take, and how it lines up with `frames`.
public struct VideoInfo: Codable, Equatable {
    /// File name only, never a path. The same base name as the session JSON
    /// with the extension `mp4`, see `RecordedSession.videoFileName`.
    public var file: String
    /// Encoded pixel width.
    public var width: Int
    /// Encoded pixel height.
    public var height: Int
    /// Video codec, `"h264"`.
    public var codec: String
    /// Frames written to the file.
    public var frameCount: Int
    /// Presentation time of the video's first frame minus the presentation
    /// time of the session's first recorded frame, in seconds, rounded to 6
    /// decimals. May be slightly negative or positive. A recorded frame with
    /// `pts` p appears in the video at time `p - startPts`.
    public var startPts: Double

    public init(file: String, width: Int, height: Int, codec: String, frameCount: Int, startPts: Double) {
        self.file = file
        self.width = width
        self.height = height
        self.codec = codec
        self.frameCount = frameCount
        self.startPts = Self.rounded(startPts, places: 6)
    }

    /// Rounds to `places` decimals. Negative zero is normalised to zero.
    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        let result = (value * scale).rounded() / scale
        return result == 0 ? 0 : result
    }
}

/// The device and build a take was recorded on.
public struct DeviceInfo: Codable, Equatable {
    /// Hardware identifier such as "iPhone17,2".
    public var model: String
    public var systemVersion: String
    public var appVersion: String
    public var appBuild: String
    /// Detector model asset, for example "pose_landmarker_full".
    public var poseModel: String
    /// Camera used, for example "front".
    public var cameraPosition: String
    /// `PushupFeatureExtractor.featureVersion` at record time.
    public var featureVersion: String

    public init(
        model: String,
        systemVersion: String,
        appVersion: String,
        appBuild: String,
        poseModel: String,
        cameraPosition: String,
        featureVersion: String
    ) {
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.poseModel = poseModel
        self.cameraPosition = cameraPosition
        self.featureVersion = featureVersion
    }
}

/// The app's own count at the end of a take.
public struct LiveResult: Codable, Equatable {
    public var reps: Int
    public var rejectedReps: Int
    /// "heuristic" or "coreml".
    public var classifier: String

    public init(reps: Int, rejectedReps: Int, classifier: String) {
        self.reps = reps
        self.rejectedReps = rejectedReps
        self.classifier = classifier
    }
}

/// One frame in compact on-disk form: landmarks are flat arrays of numbers,
/// rounded so the JSON stays small.
public struct RecordedFrame: Codable, Equatable {
    public static let landmarkCount = 33
    public static let imageStride = 5
    public static let worldStride = 3
    /// Stored in place of a nil visibility or presence.
    public static let missingValue: Double = -1

    /// Seconds since the first recorded frame, from `RawPoseFrame.timestamp`.
    public var t: Double
    /// Seconds since the first recorded frame's presentation time, nil if unknown.
    public var pts: Double?
    /// 33 * 5 values `[x, y, z, visibility, presence]` per landmark, BlazePose
    /// image convention (origin top-left, y down). nil = no body detected.
    public var lm: [Double]?
    /// 33 * 3 values `[x, y, z]` in metres per world landmark. nil = absent.
    public var wlm: [Double]?

    public init(t: Double, pts: Double?, lm: [Double]?, wlm: [Double]?) {
        self.t = t
        self.pts = pts
        self.lm = lm
        self.wlm = wlm
    }

    /// A landmark array that is not exactly 33 long, or that holds a
    /// non-finite number (which JSON cannot represent), is stored as absent.
    public init(raw: RawPoseFrame, originTimestamp: TimeInterval, originPresentationTime: TimeInterval?) {
        self.t = Self.rounded(raw.timestamp - originTimestamp, places: 6)
        if let presentation = raw.presentationTime, let origin = originPresentationTime,
           presentation.isFinite, origin.isFinite {
            self.pts = Self.rounded(presentation - origin, places: 6)
        } else {
            self.pts = nil
        }
        self.lm = raw.landmarks.flatMap(Self.flattenImage)
        self.wlm = raw.worldLandmarks.flatMap(Self.flattenWorld)
    }

    /// Inverse of `init(raw:...)`: a wrong-length array becomes nil
    /// landmarks, the `-1` sentinel becomes a nil visibility or presence,
    /// and world landmarks carry neither.
    public var rawPoseFrame: RawPoseFrame {
        RawPoseFrame(
            timestamp: t,
            presentationTime: pts,
            landmarks: Self.expandImage(lm),
            worldLandmarks: Self.expandWorld(wlm)
        )
    }

    private static func flattenImage(_ landmarks: [RawLandmark]) -> [Double]? {
        guard landmarks.count == landmarkCount else { return nil }
        var values: [Double] = []
        values.reserveCapacity(landmarkCount * imageStride)
        for landmark in landmarks {
            values.append(rounded(Double(landmark.x), places: 6))
            values.append(rounded(Double(landmark.y), places: 6))
            values.append(rounded(Double(landmark.z), places: 6))
            values.append(landmark.visibility.map { rounded(Double($0), places: 4) } ?? missingValue)
            values.append(landmark.presence.map { rounded(Double($0), places: 4) } ?? missingValue)
        }
        return values.allSatisfy(\.isFinite) ? values : nil
    }

    private static func flattenWorld(_ landmarks: [RawLandmark]) -> [Double]? {
        guard landmarks.count == landmarkCount else { return nil }
        var values: [Double] = []
        values.reserveCapacity(landmarkCount * worldStride)
        for landmark in landmarks {
            values.append(rounded(Double(landmark.x), places: 5))
            values.append(rounded(Double(landmark.y), places: 5))
            values.append(rounded(Double(landmark.z), places: 5))
        }
        return values.allSatisfy(\.isFinite) ? values : nil
    }

    private static func expandImage(_ values: [Double]?) -> [RawLandmark]? {
        guard let values, values.count == landmarkCount * imageStride else { return nil }
        return (0..<landmarkCount).map { index in
            let base = index * imageStride
            return RawLandmark(
                x: Float(values[base]),
                y: Float(values[base + 1]),
                z: Float(values[base + 2]),
                visibility: optionalScore(values[base + 3]),
                presence: optionalScore(values[base + 4])
            )
        }
    }

    private static func expandWorld(_ values: [Double]?) -> [RawLandmark]? {
        guard let values, values.count == landmarkCount * worldStride else { return nil }
        return (0..<landmarkCount).map { index in
            let base = index * worldStride
            return RawLandmark(
                x: Float(values[base]),
                y: Float(values[base + 1]),
                z: Float(values[base + 2]),
                visibility: nil,
                presence: nil
            )
        }
    }

    private static func optionalScore(_ value: Double) -> Float? {
        value == missingValue ? nil : Float(value)
    }

    /// Rounds to `places` decimals, returned as a Double so JSON prints the
    /// short form. Negative zero is normalised to zero.
    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        let result = (value * scale).rounded() / scale
        return result == 0 ? 0 : result
    }
}

/// The phone's device motion during a take, as one flat array so the JSON
/// stays small. Plain numbers only: the app converts from Core Motion.
public struct MotionStream: Codable, Equatable {
    /// Values per sample: `[t, ax, ay, az, rx, ry, rz, gx, gy, gz]`.
    public static let stride = 10

    /// Requested update rate. Real spacing varies, read `t` for the truth.
    public var rateHz: Double
    /// `stride` values per sample. `t` is seconds on the same timeline as
    /// `RecordedFrame.pts`; `a*` is user acceleration in g, `r*` rotation rate
    /// in rad/s and `g*` the gravity vector in g, all in the device frame.
    public var samples: [Double]

    public init(rateHz: Double, samples: [Double] = []) {
        self.rateHz = rateHz
        self.samples = samples
    }

    /// Whole samples held. A trailing partial sample is not counted.
    public var sampleCount: Int {
        samples.count / Self.stride
    }

    /// Appends one sample, rounding `t` to 6 decimals and the sensor values
    /// to 5. A sample holding a non-finite number is dropped, since JSON
    /// cannot represent it.
    public mutating func append(
        t: Double,
        userAcceleration: (x: Double, y: Double, z: Double),
        rotationRate: (x: Double, y: Double, z: Double),
        gravity: (x: Double, y: Double, z: Double)
    ) {
        let values = [
            t,
            userAcceleration.x, userAcceleration.y, userAcceleration.z,
            rotationRate.x, rotationRate.y, rotationRate.z,
            gravity.x, gravity.y, gravity.z,
        ]
        guard values.allSatisfy(\.isFinite) else { return }
        samples.append(Self.rounded(values[0], places: 6))
        for value in values.dropFirst() {
            samples.append(Self.rounded(value, places: 5))
        }
    }

    /// The sample at `index`, or nil when it is past the end.
    public func sample(at index: Int) -> (
        t: Double,
        userAcceleration: (x: Double, y: Double, z: Double),
        rotationRate: (x: Double, y: Double, z: Double),
        gravity: (x: Double, y: Double, z: Double)
    )? {
        guard index >= 0, index < sampleCount else { return nil }
        let base = index * Self.stride
        return (
            t: samples[base],
            userAcceleration: (samples[base + 1], samples[base + 2], samples[base + 3]),
            rotationRate: (samples[base + 4], samples[base + 5], samples[base + 6]),
            gravity: (samples[base + 7], samples[base + 8], samples[base + 9])
        )
    }

    /// Rounds to `places` decimals. Negative zero is normalised to zero.
    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        let result = (value * scale).rounded() / scale
        return result == 0 ? 0 : result
    }
}

public enum RecordedSessionError: Error, Equatable {
    case unsupportedSchema(Int)
}

extension RecordedSession {
    /// The frames mapped onto the pipeline's `PoseFrame` contract, ready to
    /// feed to a `PushupPipeline`.
    public func poseFrames() -> [PoseFrame] {
        frames.map { BlazePoseMapping.poseFrame(from: $0.rawPoseFrame) }
    }

    // MARK: - Serialisation

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> RecordedSession {
        try decode(Data(contentsOf: url))
    }

    /// Decodes a session, checking the schema number before anything else so
    /// an older or newer file reports `unsupportedSchema` rather than a
    /// missing-field error.
    public static func decode(_ data: Data) throws -> RecordedSession {
        struct SchemaProbe: Decodable { let schema: Int }
        let decoder = JSONDecoder()
        let probe = try decoder.decode(SchemaProbe.self, from: data)
        guard probe.schema == currentSchema else {
            throw RecordedSessionError.unsupportedSchema(probe.schema)
        }
        return try decoder.decode(RecordedSession.self, from: data)
    }

    // MARK: - Subject labels

    /// The subject label for the next person: the trailing number is
    /// incremented and keeps its zero padding ("S01" to "S02", "S09" to
    /// "S10", "S99" to "S100"). A label with no trailing digits gets "2"
    /// appended. Surrounding whitespace is dropped first.
    public static func nextSubject(after subject: String) -> String {
        let (prefix, digits) = splitTrailingDigits(subject)
        guard !digits.isEmpty else { return prefix + "2" }
        return prefix + stepDigits(digits, by: 1)
    }

    /// The label one step back: the trailing number is decremented at the
    /// same width ("S10" to "S09", "S100" to "S099"). The number never goes below zero,
    /// and a label with no trailing digits is returned unchanged.
    public static func previousSubject(before subject: String) -> String {
        let (prefix, digits) = splitTrailingDigits(subject)
        guard !digits.isEmpty else { return prefix }
        return prefix + stepDigits(digits, by: -1)
    }

    private static func splitTrailingDigits(_ subject: String) -> (prefix: String, digits: String) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits: [Character] = []
        var rest = Substring(trimmed)
        while let last = rest.last, last.isASCII, last.isNumber {
            digits.append(last)
            rest = rest.dropLast()
        }
        return (String(rest), String(digits.reversed()))
    }

    /// Adds or subtracts one on a string of ASCII digits, with carry, so a
    /// number of any length works. The result is zero padded back to the
    /// original width and grows only when it has to ("99" to "100").
    /// Subtracting from zero leaves it unchanged.
    private static func stepDigits(_ digits: String, by delta: Int) -> String {
        var values = digits.compactMap(\.wholeNumberValue)
        let width = values.count
        var index = width - 1
        if delta > 0 {
            while index >= 0 {
                if values[index] == 9 {
                    values[index] = 0
                    index -= 1
                } else {
                    values[index] += 1
                    break
                }
            }
            if index < 0 { values.insert(1, at: 0) }
        } else {
            guard values.contains(where: { $0 != 0 }) else { return digits }
            while index >= 0 {
                if values[index] == 0 {
                    values[index] = 9
                    index -= 1
                } else {
                    values[index] -= 1
                    break
                }
            }
        }
        return values.map(String.init).joined()
    }

    // MARK: - File names

    /// `<kind>_<yyyyMMdd-HHmmss>_<first 8 characters of id, lowercased>.json`,
    /// time in UTC. An unparseable `createdAt` falls back to the Unix epoch.
    public static func fileName(kind: Kind, createdAt: String, id: String) -> String {
        fileName(kind: kind, createdAt: parseISO8601(createdAt) ?? Date(timeIntervalSince1970: 0), id: id)
    }

    public static func fileName(kind: Kind, createdAt: Date, id: String) -> String {
        "\(kind.rawValue)_\(fileNameTimestamp(createdAt))_\(String(id.prefix(8)).lowercased()).json"
    }

    /// True only for names `fileName` can produce. Used as the guard before
    /// deleting a file, so it must reject anything else, including path
    /// components.
    public static func isRecordingFileName(_ name: String) -> Bool {
        let pattern = "^(set|negative|pose)_[0-9]{8}-[0-9]{6}_[0-9a-f]{8}\\.json\\z"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// The video file name that goes with a session file name: a trailing
    /// `.json` becomes `.mp4`. A name without that suffix gets `.mp4`
    /// appended, so the result never equals the input.
    public static func videoFileName(forSessionFileName name: String) -> String {
        let suffix = ".json"
        let base = name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
        return base + ".mp4"
    }

    /// True only for the names `videoFileName(forSessionFileName:)` produces
    /// from a name `fileName` can produce: the session pattern with `.mp4`.
    /// Used as the guard before touching a video file, so it must reject
    /// anything else, including path components.
    public static func isRecordingVideoFileName(_ name: String) -> Bool {
        let pattern = "^(set|negative|pose)_[0-9]{8}-[0-9]{6}_[0-9a-f]{8}\\.mp4\\z"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// ISO 8601 in UTC with a trailing `Z`, whole seconds.
    public static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func fileNameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
