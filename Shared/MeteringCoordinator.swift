import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

/// Drives the earned-time session: lifts the shield, schedules a
/// `DeviceActivity` monitoring window with one threshold event per minute of
/// balance, and hands the ledger bookkeeping to `DeviceActivityMonitorExtension`
/// as those thresholds fire. Main app only — this is where the per-minute
/// metering "just works" even if the app gets killed mid-session.
enum MeteringCoordinator {

    /// DeviceActivity name for the earned-time monitoring window.
    static let activityName = DeviceActivityName("earnedSession")

    /// Screen Time caps a schedule's usable event count well below what an
    /// unbounded balance could produce; 60 keeps the events dictionary sane.
    /// Any balance above this stays banked in the ledger and can be spent in
    /// a later session.
    static let maxMeteredMinutes = 60

    enum MeteringError: Error {
        case noBalance
        case noSelectionSaved
        case monitoringFailed(Error)
    }

    /// Starts a metered session against the currently banked balance.
    /// Throws if there's no balance, no saved app selection, or the
    /// underlying `DeviceActivityCenter.startMonitoring` call fails.
    static func startEarnedSession() throws {
        let balance = SharedStore.earnedBalanceMinutes
        guard balance > 0 else { throw MeteringError.noBalance }

        guard let selection = SharedStore.loadSelection() else {
            throw MeteringError.noSelectionSaved
        }

        ShieldController.removeShield()

        let meteredMinutes = min(balance, maxMeteredMinutes)
        SharedStore.sessionStartBalance = balance
        SharedStore.sessionMeteredMinutes = meteredMinutes

        let calendar = Calendar.current
        let now = Date()
        let nowComponents = calendar.dateComponents([.hour, .minute, .second], from: now)

        var endOfDayComponents = DateComponents()
        endOfDayComponents.hour = 23
        endOfDayComponents.minute = 59

        let schedule = DeviceActivitySchedule(
            intervalStart: nowComponents,
            intervalEnd: endOfDayComponents,
            repeats: false
        )

        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minute in 1...meteredMinutes {
            let eventName = DeviceActivityEvent.Name("min_\(minute)")
            events[eventName] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: [],
                threshold: DateComponents(minute: minute)
            )
        }

        do {
            try DeviceActivityCenter().startMonitoring(activityName, during: schedule, events: events)
        } catch {
            // Session failed to start — restore the shield rather than
            // leaving the user with unmetered free access.
            if let selection = SharedStore.loadSelection() {
                ShieldController.applyShield(for: selection)
            }
            throw MeteringError.monitoringFailed(error)
        }

        SharedStore.isSessionActive = true
    }

    /// Ends the current session early: stops monitoring, re-applies the
    /// shield, and marks the session inactive. Remaining balance is left
    /// untouched in the ledger.
    static func stopSession() {
        DeviceActivityCenter().stopMonitoring([activityName])
        if let selection = SharedStore.loadSelection() {
            ShieldController.applyShield(for: selection)
        }
        SharedStore.isSessionActive = false
    }
}
