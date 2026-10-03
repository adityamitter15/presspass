import Foundation
import ManagedSettings
import FamilyControls

/// Thin wrapper around a named `ManagedSettingsStore` that applies or lifts
/// the Screen Time shield for the user's selected apps/categories.
enum ShieldController {

    private static var store: ManagedSettingsStore {
        ManagedSettingsStore(named: .init("pushuptime"))
    }

    /// Locks the selected applications/categories behind the shield.
    static func applyShield(for selection: FamilyActivitySelection) {
        let store = self.store
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        if selection.categoryTokens.isEmpty {
            store.shield.applicationCategories = nil
        } else {
            store.shield.applicationCategories = .specific(selection.categoryTokens)
        }
    }

    /// Lifts the shield entirely.
    static func removeShield() {
        let store = self.store
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.clearAllSettings()
    }
}
