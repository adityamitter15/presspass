import Foundation
import PushupCore
import UIKit
import os.log

/// How this launch was configured, resolved once from the launch arguments
/// and the build. The Simulator has no camera, so it always replays the
/// bundled demo session. A DEBUG build on a device can do the same with
/// `-demo 1`. The rest (`-screen`, `-demoSpeed`, `-demoLoops`,
/// `-demoHistory`, `-demoBalance`, `-mute`, `-debugState`) steer screenshots
/// and exist in DEBUG builds only.
struct AppEnvironment {
    /// A screen the app can open on, for `-screen` (DEBUG builds only).
    enum Screen: String {
        case home
        case workout
        case summary
        case settings
    }

    /// A workout HUD state to pin for a screenshot, for `-debugState`
    /// (DEBUG builds only).
    enum DebugState: String {
        case positioning
        case shallow
        case finishing
        case nobody
    }

    let usesReplaySource: Bool
    let demoSpeed: Double
    let demoLoops: Bool
    let initialScreen: Screen?
    /// Show a few in-memory sessions when the real history is empty.
    let demoHistory: Bool
    /// Overrides the banked minutes at launch, so screenshots show a number.
    let demoBalance: Int?
    /// No sound of any kind.
    let isMuted: Bool
    let debugState: DebugState?
    /// Absolute path of a still image shown behind the skeleton in replay
    /// mode, in place of the dark placeholder, for `-demoBackdrop`.
    let demoBackdropPath: String?

    static let current = AppEnvironment(arguments: ProcessInfo.processInfo.arguments)

    private static let log = OSLog(subsystem: "com.addymitter.pushuptime", category: "AppEnvironment")
    private static let demoResource = "DemoSession"

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let position = arguments.firstIndex(of: flag), position + 1 < arguments.count else { return nil }
            return arguments[position + 1]
        }

        #if targetEnvironment(simulator)
        usesReplaySource = true
        #elseif DEBUG
        usesReplaySource = value(after: "-demo") == "1"
        #else
        usesReplaySource = false
        #endif

        demoSpeed = value(after: "-demoSpeed").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 1.0
        demoLoops = value(after: "-demoLoops") != "0"

        #if DEBUG
        initialScreen = value(after: "-screen").flatMap(Screen.init(rawValue:))
        demoHistory = value(after: "-demoHistory") == "1"
        demoBalance = value(after: "-demoBalance").flatMap(Int.init)
        isMuted = value(after: "-mute") == "1"
        debugState = value(after: "-debugState").flatMap(DebugState.init(rawValue:))
        demoBackdropPath = value(after: "-demoBackdrop")
        #else
        initialScreen = nil
        demoHistory = false
        demoBalance = nil
        isMuted = false
        debugState = nil
        demoBackdropPath = nil
        #endif
    }

    /// The `-demoBackdrop` image, loaded once; nil when none was given or it
    /// cannot be read.
    static let demoBackdropImage: UIImage? = {
        guard let path = current.demoBackdropPath else { return nil }
        return UIImage(contentsOfFile: path)
    }()

    /// The bundled demo recording: one clean set of 4 reps.
    func loadDemoSession() -> RecordedSession? {
        guard let url = Bundle.main.url(forResource: Self.demoResource, withExtension: "json") else {
            os_log(.error, log: Self.log, "DemoSession.json not found in bundle")
            return nil
        }
        do {
            return try RecordedSession.load(from: url)
        } catch {
            os_log(.error, log: Self.log, "failed to load DemoSession.json: %{public}@", String(describing: error))
            return nil
        }
    }

    /// The replay of the demo session when `usesReplaySource`, otherwise the
    /// camera. A missing or unreadable demo session falls back to the camera.
    func makePoseSource() -> PoseSource {
        if usesReplaySource, let session = loadDemoSession() {
            return ReplayPoseSource(session: session, loops: demoLoops, speed: demoSpeed)
        }
        return CameraPoseSession()
    }
}
