import Foundation
import FamilyControls

/// Thin wrapper around the App Group `UserDefaults` suite shared by the main
/// app and the DeviceActivityMonitor extension. Kept deliberately small: the
/// monitor extension runs under a strict memory ceiling (~6 MB), so this type
/// avoids pulling in anything heavier than Foundation + FamilyControls.
enum SharedStore {

    static let appGroupID = "group.com.addymitter.pushuptime"

    private static let earnedBalanceKey = "earnedBalanceMinutes"
    private static let sessionActiveKey = "sessionActive"
    private static let sessionStartBalanceKey = "sessionStartBalance"
    private static let sessionMeteredMinutesKey = "sessionMeteredMinutes"
    private static let selectionKey = "familyActivitySelection"

    private static var defaults: UserDefaults {
        guard let suite = UserDefaults(suiteName: appGroupID) else {
            // Falling back to .standard keeps the app from crashing in
            // contexts (e.g. previews) where the App Group entitlement
            // isn't provisioned, at the cost of state not being shared.
            return .standard
        }
        return suite
    }

    /// Minutes of social-media time the user has banked by exercising.
    static var earnedBalanceMinutes: Int {
        get { defaults.integer(forKey: earnedBalanceKey) }
        set { defaults.set(max(0, newValue), forKey: earnedBalanceKey) }
    }

    /// Whether a metered DeviceActivity session is currently running.
    static var isSessionActive: Bool {
        get { defaults.bool(forKey: sessionActiveKey) }
        set { defaults.set(newValue, forKey: sessionActiveKey) }
    }

    /// Snapshot of the balance taken when a session starts, so the monitor
    /// extension can compute `remaining = start - elapsedMinutes` without
    /// needing to do any subtraction bookkeeping across events.
    static var sessionStartBalance: Int {
        get { defaults.integer(forKey: sessionStartBalanceKey) }
        set { defaults.set(max(0, newValue), forKey: sessionStartBalanceKey) }
    }

    /// Number of minutes actually covered by threshold events in the current
    /// session (the balance clamped to the scheduling cap). Once this many
    /// minutes have been used, no further events will fire, so the monitor
    /// must re-shield even if banked balance remains.
    static var sessionMeteredMinutes: Int {
        get { defaults.integer(forKey: sessionMeteredMinutesKey) }
        set { defaults.set(max(0, newValue), forKey: sessionMeteredMinutesKey) }
    }

    static func saveSelection(_ selection: FamilyActivitySelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: selectionKey)
    }

    static func loadSelection() -> FamilyActivitySelection? {
        guard let data = defaults.data(forKey: selectionKey) else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    static func credit(minutes: Int) {
        earnedBalanceMinutes = earnedBalanceMinutes + minutes
    }

    static func debitOneMinute() {
        earnedBalanceMinutes = max(0, earnedBalanceMinutes - 1)
    }
}

/// Alias kept for call sites (e.g. the workout stub's debug credit button)
/// that refer to the ledger as "BalanceStore": same backing store as
/// `SharedStore`, just a friendlier name where the code is purely about the
/// earned-minutes balance.
typealias BalanceStore = SharedStore
