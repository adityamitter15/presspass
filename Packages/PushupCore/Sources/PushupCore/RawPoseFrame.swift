import Foundation

/// One camera frame's pose detection exactly as the detector reported it.
///
/// This is the unit the live camera session emits and the recorder stores,
/// so a recorded set can be replayed through `PushupPipeline` by mapping each
/// frame with `BlazePoseMapping.poseFrame(from:)`.
public struct RawPoseFrame: Equatable {
    /// The timestamp the live pipeline uses for this frame.
    public let timestamp: TimeInterval
    /// Camera presentation timestamp in seconds, nil if unknown.
    public let presentationTime: TimeInterval?
    /// 33 image-space landmarks, nil when no body was detected.
    public let landmarks: [RawLandmark]?
    /// 33 world landmarks in metres, nil when absent.
    public let worldLandmarks: [RawLandmark]?

    public init(
        timestamp: TimeInterval,
        presentationTime: TimeInterval?,
        landmarks: [RawLandmark]?,
        worldLandmarks: [RawLandmark]?
    ) {
        self.timestamp = timestamp
        self.presentationTime = presentationTime
        self.landmarks = landmarks
        self.worldLandmarks = worldLandmarks
    }
}
