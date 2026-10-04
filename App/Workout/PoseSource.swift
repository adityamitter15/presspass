import AVFoundation
import PushupCore

/// Where pose frames come from: the live camera on a device, or a recorded
/// session played back in the Simulator and for screenshots. The view models
/// depend on this, not on `CameraPoseSession`, so both run the same pipeline.
protocol PoseSource: AnyObject {
    /// Called with every frame's raw detector output, just before `onFrame`,
    /// on the main queue.
    var onRawFrame: ((RawPoseFrame) -> Void)? { get set }

    /// Called with every derived pose frame on the main queue. May carry an
    /// empty `joints` dict when nobody is in view.
    var onFrame: ((PoseFrame) -> Void)? { get set }

    /// Nil when the source has no camera image to show (replay).
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer?

    func start(completion: @escaping (Result<Void, CameraPoseSession.SessionError>) -> Void)
    func stop()
}

extension CameraPoseSession: PoseSource {
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer? {
        makeCameraPreviewLayer()
    }
}
