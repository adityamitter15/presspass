#if DEBUG
import CoreMotion
import Foundation

/// Wraps one `CMMotionManager` for the DEBUG recorder. While running it
/// receives device-motion updates on its own serial queue; between
/// `beginTake()` and `endTake()` it keeps each one, so the take can store the
/// phone's own movement next to the pose stream. Device motion needs no usage
/// description and no entitlement. Safe to call from any queue (the buffer is
/// guarded by a lock).
final class MotionRecorder: @unchecked Sendable {
    /// Requested update rate. The real spacing varies a little.
    static let updateRateHz: Double = 100

    /// The parts of a `CMDeviceMotion` the recording keeps, as plain values.
    struct Sample: Equatable, Sendable {
        /// `CMDeviceMotion.timestamp`: seconds since the device booted.
        let timestamp: TimeInterval
        /// `userAcceleration`, in g.
        let userAcceleration: (x: Double, y: Double, z: Double)
        /// `rotationRate`, in rad/s.
        let rotationRate: (x: Double, y: Double, z: Double)
        /// `gravity`, in g.
        let gravity: (x: Double, y: Double, z: Double)

        static func == (lhs: Sample, rhs: Sample) -> Bool {
            lhs.timestamp == rhs.timestamp
                && lhs.userAcceleration == rhs.userAcceleration
                && lhs.rotationRate == rhs.rotationRate
                && lhs.gravity == rhs.gravity
        }
    }

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.addymitter.pushuptime.recorder.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var isBuffering = false
    private var buffer: [Sample] = []

    /// False on hardware without motion sensors, and in the simulator.
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    deinit {
        manager.stopDeviceMotionUpdates()
    }

    /// Begins device-motion updates. Does nothing if they are unavailable or
    /// already running.
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / Self.updateRateHz
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.record(motion)
        }
    }

    /// Ends device-motion updates. Anything buffered stays until `endTake()`.
    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Clears the buffer and starts keeping samples.
    func beginTake() {
        lock.lock()
        buffer = []
        isBuffering = true
        lock.unlock()
    }

    /// Stops keeping samples and returns the ones kept since `beginTake()`,
    /// oldest first. Empty if no take was begun or no update arrived.
    func endTake() -> [Sample] {
        lock.lock()
        let samples = buffer
        buffer = []
        isBuffering = false
        lock.unlock()
        return samples
    }

    private func record(_ motion: CMDeviceMotion) {
        let sample = Sample(
            timestamp: motion.timestamp,
            userAcceleration: (motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z),
            rotationRate: (motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
            gravity: (motion.gravity.x, motion.gravity.y, motion.gravity.z)
        )
        lock.lock()
        if isBuffering { buffer.append(sample) }
        lock.unlock()
    }
}
#endif
