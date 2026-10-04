import MediaPipeTasksVision
import PushupCore

extension RawLandmark {
    /// Copies one MediaPipe landmark into the SDK-free `RawLandmark` that
    /// `BlazePoseMapping` consumes.
    init(_ landmark: NormalizedLandmark) {
        self.init(
            x: landmark.x,
            y: landmark.y,
            z: landmark.z,
            visibility: landmark.visibility?.floatValue,
            presence: landmark.presence?.floatValue
        )
    }

    /// Copies one MediaPipe world landmark (metres, origin at the hip
    /// midpoint) into a `RawLandmark`.
    init(_ landmark: Landmark) {
        self.init(
            x: landmark.x,
            y: landmark.y,
            z: landmark.z,
            visibility: landmark.visibility?.floatValue,
            presence: landmark.presence?.floatValue
        )
    }
}
