#if DEBUG
import Foundation

/// Storage for the per-open gate feasibility spike (see `docs/gate-spike.md`):
/// an event log and the expiry of the current pass, in the app's own
/// `UserDefaults`. The App Intents run inside this app's process, so the
/// intents and the UI share it without an App Group. Safe to call from any
/// thread.
enum GateSpikeStore {
    /// What happened. Raw values are the strings written to the log.
    enum Kind: String {
        case openedIntercepted = "opened_intercepted"
        case openedWithPass = "opened_with_pass"
        case closed
        case passGranted = "pass_granted"
    }

    struct Event: Codable, Equatable, Identifiable {
        /// Only for list identity.
        var id = UUID()
        var time: Date
        var kind: String
        var detail: String
    }

    /// The log keeps this many events, dropping the oldest.
    static let maxEvents = 500

    /// A gate request older than this is ignored, so a request the person
    /// never acted on cannot pop the screen up much later.
    static let gateRequestLifetime: TimeInterval = 60

    /// Posted (on any thread) when an intent asks for the gate screen.
    static let gateRequestedNotification = Notification.Name("GateSpikeStore.gateRequested")

    private static let eventsKey = "gateSpike.events"
    private static let passExpiryKey = "gateSpike.passExpiry"
    private static let gateRequestedAtKey = "gateSpike.gateRequestedAt"
    private static let lock = NSLock()
    private static var defaults: UserDefaults { .standard }

    // MARK: - Event log

    /// Appends an event, trimming the log to `maxEvents`.
    static func log(_ kind: Kind, detail: String = "", now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var events = loadEvents()
        events.append(Event(time: now, kind: kind.rawValue, detail: detail))
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: eventsKey)
        }
    }

    /// Every event, oldest first.
    static func events() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return loadEvents()
    }

    private static func loadEvents() -> [Event] {
        guard let data = defaults.data(forKey: eventsKey) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    // MARK: - Pass

    static var passExpiry: Date? {
        get { defaults.object(forKey: passExpiryKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: passExpiryKey)
            } else {
                defaults.removeObject(forKey: passExpiryKey)
            }
        }
    }

    /// True while `now` is before the pass expiry.
    static func hasValidPass(now: Date = Date()) -> Bool {
        guard let passExpiry else { return false }
        return now < passExpiry
    }

    /// Starts a pass of `minutes` from `now`, logs `pass_granted` and returns
    /// the expiry.
    @discardableResult
    static func grantPass(minutes: Int, detail: String = "", now: Date = Date()) -> Date {
        let expiry = now.addingTimeInterval(TimeInterval(minutes) * 60)
        passExpiry = expiry
        log(.passGranted, detail: detail, now: now)
        return expiry
    }

    static func clearPass() {
        passExpiry = nil
    }

    // MARK: - Gate request

    /// Records that an intercepted open wants the gate screen shown, and tells
    /// anything listening in this process.
    static func requestGate(now: Date = Date()) {
        defaults.set(now, forKey: gateRequestedAtKey)
        NotificationCenter.default.post(name: gateRequestedNotification, object: nil)
    }

    /// True once per request: returns whether a recent request is waiting and
    /// clears it.
    static func consumeGateRequest(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let requestedAt = defaults.object(forKey: gateRequestedAtKey) as? Date else { return false }
        defaults.removeObject(forKey: gateRequestedAtKey)
        return now.timeIntervalSince(requestedAt) <= gateRequestLifetime
    }
}
#endif
