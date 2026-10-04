#if DEBUG
import AppIntents
import Foundation

/// The action for a Shortcuts personal automation "When [app] is opened".
///
/// With no valid pass it logs `opened_intercepted`, asks for the gate screen
/// and brings this app to the foreground. With a valid pass it logs
/// `opened_with_pass` and returns without touching the foreground, so the
/// opened app carries on. The result is always `needsGate` (true when the
/// gate was requested), so a shortcut can branch on it with If and Open App
/// on any iOS version.
///
/// Bringing the app forward must be conditional, so `openAppWhenRun` (which
/// always opens the app) is not used. Instead, per iOS version:
/// - iOS 26 and later: `supportedModes` includes `.foreground(.dynamic)` and
///   `perform()` calls `continueInForeground(alwaysConfirm: false)` only when
///   the gate is needed.
/// - iOS 16.4 to 25: the intent conforms to `ForegroundContinuableIntent`
///   (deprecated in 26 but still present) and `perform()` calls
///   `requestToContinueInForeground()` only when the gate is needed.
/// - iOS 16.0 to 16.3: no foreground continuation exists. The intent only
///   returns `needsGate`, and the shortcut does the opening.
/// Nothing here has been run on a device yet.
struct PressPassGateIntent: AppIntent {
    static let title: LocalizedStringResource = "PressPass Gate"
    static let description = IntentDescription(
        "Run when a guarded app is opened. Brings PressPass forward unless a pass is active."
    )

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    /// The name of the app the automation is for, kept in the event log.
    @Parameter(title: "App")
    var app: String?

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let name = app ?? ""
        if GateSpikeStore.hasValidPass() {
            GateSpikeStore.log(.openedWithPass, detail: name)
            return .result(value: false)
        }
        GateSpikeStore.log(.openedIntercepted, detail: name)
        GateSpikeStore.requestGate()
        await bringToForeground()
        return .result(value: true)
    }

    /// Foreground continuation on the systems that have it. A failure (for
    /// example the person declining a prompt) is not an error for the
    /// shortcut: it still gets `needsGate` and can open the app itself.
    private func bringToForeground() async {
        if #available(iOS 26.0, *) {
            try? await continueInForeground(alwaysConfirm: false)
        } else if #available(iOS 16.4, *) {
            try? await requestToContinueInForeground { () }
        }
    }
}

@available(iOS 16.4, *)
extension PressPassGateIntent: ForegroundContinuableIntent {}

/// The action for a personal automation "When [app] is closed".
struct PressPassSessionEndIntent: AppIntent {
    static let title: LocalizedStringResource = "PressPass Session End"
    static let description = IntentDescription("Run when a guarded app is closed. Logs the close.")

    /// The name of the app the automation is for, kept in the event log.
    @Parameter(title: "App")
    var app: String?

    func perform() async throws -> some IntentResult {
        GateSpikeStore.log(.closed, detail: app ?? "")
        return .result()
    }
}

/// Makes both actions appear in the Shortcuts app without any setup.
struct GateSpikeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PressPassGateIntent(),
            phrases: ["Run the PressPass gate in \(.applicationName)"],
            shortTitle: "PressPass Gate",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: PressPassSessionEndIntent(),
            phrases: ["End the PressPass session in \(.applicationName)"],
            shortTitle: "PressPass Session End",
            systemImageName: "lock.open"
        )
    }
}
#endif
