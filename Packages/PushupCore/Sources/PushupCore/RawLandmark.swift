/// One pose landmark exactly as the detector reports it (BlazePose
/// convention: x and y normalised to [0, 1], origin top-left, y down), kept
/// free of any detector SDK type so the mapping can be tested and replayed
/// off-device.
public struct RawLandmark: Codable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let visibility: Float?
    public let presence: Float?

    public init(x: Float, y: Float, z: Float, visibility: Float?, presence: Float?) {
        self.x = x
        self.y = y
        self.z = z
        self.visibility = visibility
        self.presence = presence
    }
}
