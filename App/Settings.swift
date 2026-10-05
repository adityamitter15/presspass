import Foundation

/// User preferences, stored in `UserDefaults` under these keys so both
/// `@AppStorage` in views and the workout model read the same values.
enum AppSettings {
    enum Key {
        static let soundMode = "settings.soundMode"
        static let autoFinish = "settings.autoFinish"
        static let debugOverlay = "settings.debugOverlay"
    }

    /// How the workout talks back.
    enum SoundMode: String, CaseIterable, Identifiable {
        case off
        case ticks
        case voice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .ticks: "Ticks"
            case .voice: "Voice"
            }
        }

        static let `default`: SoundMode = .voice
    }

    static var soundMode: SoundMode {
        UserDefaults.standard.string(forKey: Key.soundMode).flatMap(SoundMode.init(rawValue:)) ?? .default
    }

    /// Whether the workout finishes by itself when the person gets up.
    static var autoFinish: Bool {
        UserDefaults.standard.object(forKey: Key.autoFinish) as? Bool ?? true
    }
}
