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

    /// Called with the camera's own sample buffer for every camera frame that
    /// will be delivered as a pose frame, before pose detection runs on it.
    /// The buffers are portrait and already mirrored, so they show exactly
    /// what the pose model sees. Used by the DEBUG recorder to save video.
    ///
    /// Called on the source's own processing queue, NOT the main queue, so
    /// the closure must be safe to run off the main actor and must return
    /// quickly: it holds up pose detection. The property itself may be set
    /// from any queue. A source with no camera (replay) never calls it.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)? { get set }

    /// Called on the main queue when the system takes the camera away from
    /// the app (another app on screen, a call, heat) with a message that says
    /// why in plain words, and again with nil when the camera comes back. A
    /// source with no camera never calls it.
    var onInterruption: ((String?) -> Void)? { get set }

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
