#if DEBUG
import Foundation
import PushupCore
import SwiftUI

/// The `UserDefaults` keys the recorder's setup is kept under, so it survives
/// between takes and launches. `@AppStorage` in the views and the view model
/// both go through these.
enum RecorderPrefs {
    static let kind = "recorder.kind"
    static let subject = "recorder.subject"
    static let lighting = "recorder.lighting"
    static let distance = "recorder.distance"
    static let clothing = "recorder.clothing"
    static let tempo = "recorder.tempo"
    static let variant = "recorder.variant"
    static let cheat = "recorder.cheat"
    static let poseLabel = "recorder.poseLabel"
    static let notes = "recorder.notes"
    static let saveVideo = "recorder.saveVideo"
    static let countVisible = "recorder.countVisible"

    /// The setup as currently stored, for launches that start a take without
    /// the setup screen (screenshots).
    static func currentSetup() -> RecordingSetup {
        let defaults = UserDefaults.standard
        func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        let kind: RecordedSession.Kind = value(Self.kind, .set)
        return RecordingSetup(
            kind: kind,
            subject: defaults.string(forKey: subject) ?? "S01",
            tags: RecordedSession.Tags(
                lighting: value(lighting, .indoorBright),
                distance: value(distance, .mid),
                clothing: value(clothing, .fitted),
                tempo: value(tempo, .normal),
                variant: value(variant, .standard),
                cheat: kind == .set ? value(cheat, .none) : .none
            ),
            poseLabel: value(poseLabel, .up),
            notes: defaults.string(forKey: notes) ?? "",
            saveVideo: defaults.object(forKey: saveVideo) as? Bool ?? true,
            countVisible: defaults.object(forKey: countVisible) as? Bool ?? true
        )
    }

    /// "This take is" goes back to real press-ups after every take, saved or
    /// discarded, so a cheat tag cannot be carried to the next person.
    /// `@AppStorage` in the setup view picks the change up.
    static func resetCheat() {
        UserDefaults.standard.set(RecordedSession.Tags.Cheat.none.rawValue, forKey: cheat)
    }
}

// MARK: - Words

extension RecordedSession.Kind {
    var title: String {
        switch self {
        case .set: "Set"
        case .negative: "Negative"
        case .pose: "Held pose"
        }
    }
}

extension RecordedSession.Tags.Lighting {
    var title: String {
        switch self {
        case .daylight: "Daylight"
        case .indoorBright: "Indoor bright"
        case .dim: "Dim"
        }
    }
}

extension RecordedSession.Tags.Distance {
    var title: String {
        switch self {
        case .near: "Near"
        case .mid: "Mid"
        case .far: "Far"
        }
    }
}

extension RecordedSession.Tags.Clothing {
    var title: String {
        switch self {
        case .fitted: "Fitted"
        case .loose: "Loose"
        }
    }
}

extension RecordedSession.Tags.Tempo {
    var title: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        case .na: "n/a"
        }
    }
}

extension RecordedSession.Tags.Variant {
    var title: String {
        switch self {
        case .standard: "Standard"
        case .knuckle: "Knuckle"
        case .knee: "Knee"
        case .wide: "Wide"
        case .narrow: "Narrow"
        case .na: "n/a"
        }
    }

    /// The variants a set can be tagged with.
    static let choices: [RecordedSession.Tags.Variant] = [.standard, .knuckle, .knee, .wide, .narrow]
}

extension RecordedSession.Tags.Tempo {
    static let choices: [RecordedSession.Tags.Tempo] = [.slow, .normal, .fast]
}

extension RecordedSession.Tags.Cheat {
    /// The option as worded under "This take is".
    var title: String {
        switch self {
        case .none: "Real press-ups"
        case .halfReps: "Half reps"
        case .armWave: "Arm wave"
        case .phoneMoved: "Phone moved"
        case .videoReplay: "Video replay"
        case .other: "Other cheat"
        }
    }

    /// The loud name of a cheat take, for the Start button and the banner.
    var loudName: String {
        switch self {
        case .none: ""
        case .halfReps: "HALF-REP"
        case .armWave: "ARM-WAVE"
        case .phoneMoved: "PHONE-MOVED"
        case .videoReplay: "VIDEO-REPLAY"
        case .other: "OTHER-CHEAT"
        }
    }

    /// What to type as the count for this kind of take.
    var countAdvice: String {
        switch self {
        case .none: ""
        case .halfReps: "count only full reps"
        default: "count 0"
        }
    }
}

extension PoseLabel {
    var title: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .notPushup: "Not a press-up"
        }
    }

    var detail: String {
        switch self {
        case .up: "Top position, arms extended"
        case .down: "Bottom position, chest low"
        case .notPushup: "Standing, sitting, anything else"
        }
    }

    static let choices: [PoseLabel] = [.up, .down, .notPushup]
}

/// The wording of what the next take will be, shared by the Start button and
/// the banner above it.
enum RecorderCopy {
    /// True when the take is anything other than ordinary press-ups: a cheat
    /// or a negative. Those turn the Start button and the banner amber.
    static func isUnusual(kind: RecordedSession.Kind, cheat: RecordedSession.Tags.Cheat) -> Bool {
        switch kind {
        case .set: cheat != .none
        case .negative: true
        case .pose: false
        }
    }

    static func startTitle(
        subject: String,
        kind: RecordedSession.Kind,
        variant: RecordedSession.Tags.Variant,
        cheat: RecordedSession.Tags.Cheat,
        poseLabel: PoseLabel
    ) -> String {
        let who = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .set:
            if cheat == .none { return "Start: \(who), set, \(variant.rawValue)" }
            return "Start: \(who), \(cheat.loudName) take (\(cheat.countAdvice))"
        case .negative:
            return "Start: \(who), NEGATIVE take (nothing should count)"
        case .pose:
            return "Start: \(who), held pose, \(poseLabel.title.lowercased())"
        }
    }

    /// A short description of a running take, for the live screen.
    static func liveLabel(_ setup: RecordingSetup) -> String {
        switch setup.kind {
        case .set:
            if setup.tags.cheat == .none { return "\(setup.subject), set, \(setup.tags.variant.rawValue)" }
            return "\(setup.subject), \(setup.tags.cheat.loudName) take"
        case .negative: return "\(setup.subject), NEGATIVE take"
        case .pose: return "\(setup.subject), held pose, \(setup.poseLabel.title.lowercased())"
        }
    }

    /// The banner above Start for an unusual take, nil for an ordinary one.
    static func banner(kind: RecordedSession.Kind, cheat: RecordedSession.Tags.Cheat) -> String? {
        switch kind {
        case .set where cheat != .none:
            "This take is tagged \(cheat.loudName). It is not a normal set (\(cheat.countAdvice)). Change \"This take is\" if that is wrong."
        case .negative:
            "Negative take: nothing should count, and the count is saved as 0."
        default:
            nil
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Demo takes (-demoRecordings 1)

/// Three sample takes for screenshots. They live in memory only.
enum RecordingDemo {
    static var takes: [RecordingSummary] {
        let now = Date()
        func tags(_ variant: RecordedSession.Tags.Variant, _ cheat: RecordedSession.Tags.Cheat, tempo: RecordedSession.Tags.Tempo = .normal) -> RecordedSession.Tags {
            RecordedSession.Tags(
                lighting: .indoorBright, distance: .mid, clothing: .fitted,
                tempo: tempo, variant: variant, cheat: cheat
            )
        }
        return [
            RecordingSummary(
                url: URL(fileURLWithPath: "/demo/set_demo_0001.json"),
                kind: .set, trueReps: 8, liveReps: 8, subject: "S07",
                tags: tags(.knuckle, .none),
                notes: "Wooden floor",
                createdAt: now.addingTimeInterval(-4 * 60), frameCount: 1260, hasVideo: true,
                countVisible: true
            ),
            RecordingSummary(
                url: URL(fileURLWithPath: "/demo/set_demo_0002.json"),
                kind: .set, trueReps: 5, liveReps: 7, subject: "S07",
                tags: tags(.standard, .halfReps, tempo: .fast),
                createdAt: now.addingTimeInterval(-11 * 60), frameCount: 980, hasVideo: true,
                countVisible: false
            ),
            RecordingSummary(
                url: URL(fileURLWithPath: "/demo/negative_demo_0003.json"),
                kind: .negative, trueReps: 0, liveReps: 0, subject: "S06",
                tags: tags(.na, .none, tempo: .na),
                notes: "Walking through the frame",
                createdAt: now.addingTimeInterval(-26 * 60), frameCount: 610, hasVideo: false,
                countVisible: true
            ),
        ]
    }
}
#endif
