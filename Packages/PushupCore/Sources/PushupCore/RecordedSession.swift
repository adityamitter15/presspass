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
        frames: [RecordedFrame]
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
