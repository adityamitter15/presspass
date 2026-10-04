#if DEBUG
import AVFoundation
import CoreMedia
import Foundation
import os.log

/// Writes the camera frames of one recorder take to an H.264 MP4 file, with no
/// audio. It is configured lazily from the first sample buffer it is given, so
/// the output size follows whatever the capture session actually delivers.
///
/// The sample buffers are the same portrait, already mirrored buffers the pose
/// model sees, so no transform is applied: the video shows exactly what was
/// analysed.
///
/// `append` is meant for the camera's processing queue and `finish` and
/// `cancel` for the main queue, but every method is safe from any queue: all
/// state is guarded by one lock, and nothing under the lock blocks (the
/// encoder works asynchronously). One writer is one take; make a new one for
/// the next.
final class VideoTakeWriter: @unchecked Sendable {
    /// What `finish` reports about the file that was written.
    struct Summary: Equatable, Sendable {
        /// Presentation time of the first frame in the file, on the camera's
        /// clock (host-clock seconds since boot). Pose frames use the same clock.
        let firstPresentationTime: CMTime
        /// Frames written to the file.
        let frameCount: Int
        /// Frames that arrived while the encoder was not ready, or whose time
        /// did not advance, and so are missing from the file.
        let droppedFrames: Int
        /// Encoded pixel size.
        let width: Int
        let height: Int
    }

    enum WriterError: Error, LocalizedError {
        case noFrames
        case cannotStart(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "No video frames were captured."
            case .cannotStart(let reason): return "Could not start the video file: \(reason)"
            case .failed(let reason): return "Writing the video file failed: \(reason)"
            }
        }
    }

    /// Output frames fit inside this box, portrait.
    static let maxSize = (width: 720, height: 1280)
    static let averageBitRate = 4_000_000
    static let frameRate = 30
    static let keyFrameInterval = 30

    private enum State {
        /// No frame yet, nothing created.
        case idle
        case writing
        /// `finish` was called; the encoder is flushing.
        case finishing
        case finished
        case cancelled
        /// Could not be set up, or the encoder reported an error.
        case failed(WriterError)
    }

    private static let log = OSLog(subsystem: "com.addymitter.pushuptime", category: "VideoTakeWriter")

    private let outputURL: URL
    private let lock = NSLock()
    private var state: State = .idle
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPresentationTime: CMTime = .invalid
    private var lastPresentationTime: CMTime = .invalid
    private var appendedFrames = 0
    private var droppedFrames = 0
    private var outputWidth = 0
    private var outputHeight = 0

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Adds one camera frame. The first call creates the file and starts the
    /// writing session at that frame's presentation time. A frame that cannot
    /// be taken now is dropped and counted, never waited for. Does nothing
    /// after `finish`, `cancel` or a failure.
    func append(_ sampleBuffer: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isNumeric else { return }

        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            do {
                try startWriting(with: sampleBuffer, at: presentationTime)
            } catch {
                fail(error)
                return
            }
        case .writing:
            break
        case .finishing, .finished, .cancelled, .failed:
            return
        }

        guard let writer, let input else { return }
        if writer.status == .failed {
            fail(writer.error ?? WriterError.failed("unknown error"))
            return
        }
        guard presentationTime > lastPresentationTime || appendedFrames == 0 else {
            droppedFrames += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        if input.append(sampleBuffer) {
            appendedFrames += 1
            lastPresentationTime = presentationTime
        } else {
            fail(writer.error ?? WriterError.failed("the encoder refused a frame"))
        }
    }

    /// Ends the file. `completion` runs on the main queue with the summary,
    /// or with an error (and no file left behind) when no frame was ever
    /// written or the file could not be completed.
    func finish(completion: @escaping (Result<Summary, Error>) -> Void) {
        lock.lock()
        let pending: (AVAssetWriter, AVAssetWriterInput)?
        var immediate: Result<Summary, Error>?
        var removePartialFile = true

        switch state {
        case .idle:
            state = .finished
            pending = nil
            immediate = .failure(WriterError.noFrames)
        case .writing:
            if appendedFrames == 0 {
                state = .finished
                pending = nil
                immediate = .failure(WriterError.noFrames)
                writer?.cancelWriting()
            } else if let writer, let input {
                state = .finishing
                pending = (writer, input)
            } else {
                state = .finished
                pending = nil
                immediate = .failure(WriterError.noFrames)
            }
        case .failed(let error):
            state = .finished
            pending = nil
            immediate = .failure(error)
            writer?.cancelWriting()
        case .finishing, .finished, .cancelled:
            // Nothing to do, and a file that is finished or still being
            // finished must not be touched.
            pending = nil
            removePartialFile = false
            immediate = .failure(WriterError.failed("the take was already finished or cancelled"))
        }
        lock.unlock()

        if let immediate {
            if removePartialFile { removeFile() }
            DispatchQueue.main.async { completion(immediate) }
            return
        }
        guard let (writer, input) = pending else { return }

        input.markAsFinished()
        writer.finishWriting { [self] in
            let result: Result<Summary, Error>
            lock.lock()
            if writer.status == .completed {
                state = .finished
                result = .success(Summary(
                    firstPresentationTime: firstPresentationTime,
                    frameCount: appendedFrames,
                    droppedFrames: droppedFrames,
                    width: outputWidth,
                    height: outputHeight
                ))
            } else {
                let error = WriterError.failed(writer.error?.localizedDescription ?? "unknown error")
                state = .failed(error)
                result = .failure(error)
            }
            lock.unlock()
            if case .failure = result { removeFile() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Abandons the take and deletes the partial file. Safe to call at any
    /// time, more than once, and after `finish` (which then leaves nothing to
    /// cancel; it does not delete a completed file).
    func cancel() {
        lock.lock()
        let wasActive: Bool
        switch state {
        case .idle, .writing, .failed:
            wasActive = true
            state = .cancelled
            writer?.cancelWriting()
        case .finishing, .finished, .cancelled:
            wasActive = false
        }
        lock.unlock()
        if wasActive { removeFile() }
    }

    // MARK: - Setup (lock held)

    private func startWriting(with sampleBuffer: CMSampleBuffer, at presentationTime: CMTime) throws {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw WriterError.cannotStart("the frame has no format")
        }
        let source = CMVideoFormatDescriptionGetDimensions(format)
        let size = Self.outputSize(sourceWidth: Int(source.width), sourceHeight: Int(source.height))

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw WriterError.cannotStart(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.averageBitRate,
                AVVideoExpectedSourceFrameRateKey: Self.frameRate,
                AVVideoMaxKeyFrameIntervalKey: Self.keyFrameInterval,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // No B-frames: presentation order equals decode order, so the
                // first frame in the file is the first frame we appended.
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw WriterError.cannotStart("the encoder rejected the video settings")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriterError.cannotStart(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: presentationTime)

        self.writer = writer
        self.input = input
        firstPresentationTime = presentationTime
        outputWidth = size.width
        outputHeight = size.height
        state = .writing
    }

    private func fail(_ error: Error) {
        let wrapped = (error as? WriterError) ?? WriterError.failed(error.localizedDescription)
        os_log(.error, log: Self.log, "video writer failed: %{public}@", wrapped.localizedDescription)
        state = .failed(wrapped)
        writer?.cancelWriting()
        removeFile()
    }

    private func removeFile() {
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Size

    /// `sourceWidth` by `sourceHeight` scaled to fit inside `maxSize`, keeping
    /// the aspect ratio, never enlarged, and rounded down to even numbers
    /// (H.264 needs them), at least 2.
    static func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (2, 2) }
        let scale = min(
            1,
            Double(maxSize.width) / Double(sourceWidth),
            Double(maxSize.height) / Double(sourceHeight)
        )
        func even(_ value: Double) -> Int {
            max(2, Int(value.rounded(.down)) / 2 * 2)
        }
        return (even(Double(sourceWidth) * scale), even(Double(sourceHeight) * scale))
    }
}
#endif
