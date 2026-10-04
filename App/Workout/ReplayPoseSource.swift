import AVFoundation
import Foundation
import PushupCore

/// Plays a `RecordedSession` back through the same two callbacks the camera
/// uses, in real time, so the workout screen can run in the Simulator and for
/// screenshots without a camera. Frames are spaced by the recorded `t`
/// differences divided by `speed`, and delivered on the main queue, raw frame
/// first. Everything here is meant to be used from the main queue, like the
/// view models that own it.
///
/// Timestamps handed to the pipeline keep rising across loops (each loop adds
/// the length of the loops before it), so the rep state machine sees one long
/// session, not a clock that jumps back. Between loops the person "leaves":
/// `loopGap` seconds of frames with no landmarks.
final class ReplayPoseSource: PoseSource {
    /// Seconds of no-body frames between two loops.
    static let loopGap: TimeInterval = 1.5

    var onFrame: ((PoseFrame) -> Void)?
    var onRawFrame: ((RawPoseFrame) -> Void)?
    /// Stored to satisfy `PoseSource`; a replay has no camera, so it never calls this.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let loops: Bool
    private let speed: Double
    /// One loop of frames with timestamps relative to its first frame,
    /// followed by the no-body gap when looping.
    private let template: [RawPoseFrame]
    /// Session seconds one loop takes, gap included. The next loop's first
    /// frame lands one frame interval after the last gap frame.
    private let loopLength: TimeInterval
    private let frameInterval: TimeInterval

    private var timer: DispatchSourceTimer?
    private var runStart = DispatchTime.now()
    private var index = 0
    private var loop = 0
    /// Added to every timestamp, so a second `start()` carries on after the first run.
    private var timestampBase: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0

    init(session: RecordedSession, loops: Bool = true, speed: Double = 1.0) {
        self.loops = loops
        self.speed = max(speed, 0.01)

        let frames = session.frames.map(\.rawPoseFrame)
        let first = frames.first?.timestamp ?? 0
        var shifted = frames.map { frame in
            RawPoseFrame(
                timestamp: frame.timestamp - first,
                presentationTime: frame.presentationTime,
                landmarks: frame.landmarks,
                worldLandmarks: frame.worldLandmarks
            )
        }
        let span = shifted.last?.timestamp ?? 0
        let interval = shifted.count > 1 ? span / Double(shifted.count - 1) : 1.0 / 30
        frameInterval = interval > 0 ? interval : 1.0 / 30

        if loops, let last = shifted.last {
            let gapFrames = max(1, Int((Self.loopGap / frameInterval).rounded()))
            for step in 1...gapFrames {
                let offset = Double(step) * frameInterval
                shifted.append(RawPoseFrame(
                    timestamp: last.timestamp + offset,
                    presentationTime: last.presentationTime.map { $0 + offset },
                    landmarks: nil,
                    worldLandmarks: nil
                ))
            }
        }
        template = shifted
        loopLength = (shifted.last?.timestamp ?? 0) + frameInterval
    }

    /// No camera image to show.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer? { nil }

    /// Starts (or restarts, after a non-looping run ended) the playback from
    /// the first frame. Safe to call while already playing.
    func start(completion: @escaping (Result<Void, CameraPoseSession.SessionError>) -> Void) {
        if timer == nil {
            index = 0
            loop = 0
            timestampBase = template.isEmpty ? 0 : lastTimestamp + frameInterval
            runStart = DispatchTime.now()
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.setEventHandler { [weak self] in self?.pump() }
            timer = source
            source.schedule(deadline: .now())
            source.resume()
        }
        DispatchQueue.main.async { completion(.success(())) }
    }

    /// Stops delivering frames. Safe to call more than once, or without a start.
    func stop() {
        guard let timer else { return }
        timer.setEventHandler(handler: nil)
        timer.cancel()
        self.timer = nil
    }

    /// Delivers every frame that is due, then sleeps until the next one.
    private func pump() {
        guard let timer else { return }
        while index < template.count {
            let due = Double(loop) * loopLength + template[index].timestamp
            let deadline = runStart + .nanoseconds(Int(due / speed * 1_000_000_000))
            let now = DispatchTime.now()
            if deadline > now {
                timer.schedule(deadline: deadline)
                return
            }
            // After a long stall (app suspended) catch up by moving the clock
            // rather than firing a burst of frames. Timestamps are not affected.
            let lag = now.uptimeNanoseconds - deadline.uptimeNanoseconds
            if lag > 500_000_000 {
                runStart = runStart + .nanoseconds(Int(lag))
            }
            deliver(template[index], loopOffset: Double(loop) * loopLength + timestampBase)
            index += 1
            if index == template.count, loops {
                index = 0
                loop += 1
            }
        }
        // A non-looping run is over.
        stop()
    }

    private func deliver(_ frame: RawPoseFrame, loopOffset: TimeInterval) {
        let raw = RawPoseFrame(
            timestamp: frame.timestamp + loopOffset,
            presentationTime: frame.presentationTime.map { $0 + loopOffset },
            landmarks: frame.landmarks,
            worldLandmarks: frame.worldLandmarks
        )
        lastTimestamp = raw.timestamp
        let pose = BlazePoseMapping.poseFrame(from: raw)
        onRawFrame?(raw)
        onFrame?(pose)
    }
}

extension ReplayPoseSource {
    /// The rep count the pipeline reaches over one full pass of `session`,
    /// computed at once without any timing. Used to show the finished-workout
    /// summary without waiting for a real-time run.
    static func finalRepCount(of session: RecordedSession) -> Int {
        let pipeline = PushupPipeline(classifier: PoseClassifierFactory.makeDefault())
        var reps = 0
        for frame in session.poseFrames() {
            reps = pipeline.process(frame).reps
        }
        return reps
    }
}
