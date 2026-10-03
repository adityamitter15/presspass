import DeviceActivity

// Kept minimal on purpose: DeviceActivityMonitor extensions run under a
// strict (~6 MB) memory ceiling, so no SwiftUI or heavier frameworks here.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity == MeteringActivity.name else { return }

        // Midnight rollover: re-lock the shield, remaining balance (if any)
        // persists in the ledger for the next day.
        if let selection = SharedStore.loadSelection() {
            ShieldController.applyShield(for: selection)
        }
        SharedStore.isSessionActive = false
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard activity == MeteringActivity.name else { return }
        guard let minutesUsed = MeteringActivity.minute(fromEventName: event) else { return }

        let startBalance = SharedStore.sessionStartBalance
        let remaining = max(0, startBalance - minutesUsed)
        SharedStore.earnedBalanceMinutes = remaining

        // Re-shield when the balance is spent, and also when the metered
        // window is exhausted (balance above the scheduling cap stays banked
        // but must not become unmetered free access once events run out).
        if remaining <= 0 || minutesUsed >= SharedStore.sessionMeteredMinutes {
            if let selection = SharedStore.loadSelection() {
                ShieldController.applyShield(for: selection)
            }
            SharedStore.isSessionActive = false
        }
    }
}

/// Local mirror of the activity name so this extension target doesn't need
/// to depend on `MeteringCoordinator` (main-app only).
enum MeteringActivity {
    static let name = DeviceActivityName("earnedSession")

    /// Parses "min_12" -> 12.
    static func minute(fromEventName name: DeviceActivityEvent.Name) -> Int? {
        let raw = name.rawValue
        guard raw.hasPrefix("min_") else { return nil }
        return Int(raw.dropFirst("min_".count))
    }
}
