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
    static let hands = "recorder.hands"
    static let support = "recorder.support"
    static let width = "recorder.width"
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
        let handsChoice: RecordedSession.Tags.Hands = value(hands, .palms)
        let supportChoice: RecordedSession.Tags.Support = value(support, .toes)
        let widthChoice: RecordedSession.Tags.Width = value(width, .normal)
        return RecordingSetup(
            kind: kind,
            subject: defaults.string(forKey: subject) ?? "S01",
            tags: RecordedSession.Tags(
                lighting: value(lighting, .indoorBright),
                distance: value(distance, .mid),
                clothing: value(clothing, .fitted),
                tempo: value(tempo, .normal),
                variant: RecordedSession.Tags.variant(hands: handsChoice, support: supportChoice, width: widthChoice),
                cheat: kind == .set ? value(cheat, .none) : .none,
                hands: handsChoice,
                support: supportChoice,
                width: widthChoice
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

extension RecordedSession.Tags.Hands {
    var title: String {
        switch self {
        case .palms: "Palms"
        case .knuckles: "Knuckles"
        }
    }
}

extension RecordedSession.Tags.Support {
    /// Shown under "Legs".
    var title: String {
        switch self {
        case .toes: "Toes"
        case .knees: "Knees"
        }
    }
}

extension RecordedSession.Tags.Width {
    var title: String {
        switch self {
        case .normal: "Normal"
        case .wide: "Wide"
        case .narrow: "Narrow"
        }
    }
}

extension RecordedSession.Tags {
    /// What the press-ups were done on, in words, listing only what differs
    /// from the default of palms, toes and a normal width: "knuckles",
    /// "knees", "knuckles, knees", "wide, knees". Empty for the default. Reads
    /// `resolved`, so a take recorded before the three fields existed shows
    /// correctly.
    var techniqueSummary: String {
        let choice = resolved
        var words: [String] = []
        if choice.hands == .knuckles { words.append("knuckles") }
        switch choice.width {
        case .normal: break
        case .wide: words.append("wide")
        case .narrow: words.append("narrow")
        }
        if choice.support == .knees { words.append("knees") }
        return words.joined(separator: ", ")
    }

    /// `techniqueSummary` starting with a capital, for a pill.
    var techniqueTitle: String {
        let summary = techniqueSummary
        return summary.prefix(1).uppercased() + summary.dropFirst()
    }

    /// Sets all three choices at once and recomputes `variant` from them, so
    /// the legacy summary and the precise fields never disagree. The two
    /// fields not being changed are first filled in from `resolved`, which is
    /// what turns a take recorded before the fields existed into one that has
    /// them.
    mutating func setTechnique(
        hands: Hands? = nil,
        support: Support? = nil,
        width: Width? = nil
    ) {
        let current = resolved
        let newHands = hands ?? current.hands
        let newSupport = support ?? current.support
        let newWidth = width ?? current.width
        self.hands = newHands
        self.support = newSupport
        self.width = newWidth
        variant = Self.variant(hands: newHands, support: newSupport, width: newWidth)
    }

    /// This tag set with all three choices filled in and `variant` consistent
    /// with them.
    var withTechniqueFilled: RecordedSession.Tags {
        var copy = self
        copy.setTechnique()
        return copy
    }
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
        tags: RecordedSession.Tags,
        cheat: RecordedSession.Tags.Cheat,
        poseLabel: PoseLabel
    ) -> String {
        let who = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .set:
            if cheat == .none { return "Start: \(joined(who, "set", tags.techniqueSummary))" }
            return "Start: \(who), \(cheat.loudName) take (\(cheat.countAdvice))"
        case .negative:
            return "Start: \(who), NEGATIVE take (nothing should count)"
        case .pose:
            return "Start: \(who), held pose, \(poseLabel.title.lowercased())"
        }
    }

    /// The parts joined with commas, leaving out any that is empty.
    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A short description of a running take, for the live screen.
    static func liveLabel(_ setup: RecordingSetup) -> String {
        switch setup.kind {
        case .set:
            if setup.tags.cheat == .none { return joined(setup.subject, "set", setup.tags.techniqueSummary) }
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
        func tags(
            _ variant: RecordedSession.Tags.Variant,
            _ cheat: RecordedSession.Tags.Cheat,
            tempo: RecordedSession.Tags.Tempo = .normal,
            technique: (RecordedSession.Tags.Hands, RecordedSession.Tags.Support, RecordedSession.Tags.Width)? = nil
        ) -> RecordedSession.Tags {
            RecordedSession.Tags(
                lighting: .indoorBright, distance: .mid, clothing: .fitted,
                tempo: tempo, variant: variant, cheat: cheat,
                hands: technique?.0, support: technique?.1, width: technique?.2
            )
        }
        return [
            RecordingSummary(
                url: URL(fileURLWithPath: "/demo/set_demo_0001.json"),
                kind: .set, trueReps: 8, liveReps: 8, subject: "S07",
                tags: tags(.knuckleKnee, .none, technique: (.knuckles, .knees, .normal)),
                notes: "Wooden floor",
                createdAt: now.addingTimeInterval(-4 * 60), frameCount: 1260, hasVideo: true,
                countVisible: true
            ),
            RecordingSummary(
                url: URL(fileURLWithPath: "/demo/set_demo_0002.json"),
                kind: .set, trueReps: 5, liveReps: 7, subject: "S07",
                tags: tags(.standard, .halfReps, tempo: .fast, technique: (.palms, .toes, .normal)),
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
