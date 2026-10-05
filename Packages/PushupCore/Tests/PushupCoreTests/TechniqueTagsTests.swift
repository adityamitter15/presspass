import Foundation
import Testing
import PushupCore

private typealias Tags = RecordedSession.Tags
private typealias Hands = Tags.Hands
private typealias Support = Tags.Support
private typealias Width = Tags.Width
private typealias Variant = Tags.Variant

private func tags(
    variant: Variant,
    hands: Hands? = nil,
    support: Support? = nil,
    width: Width? = nil
) -> Tags {
    Tags(
        lighting: .indoorBright,
        distance: .mid,
        clothing: .fitted,
        tempo: .normal,
        variant: variant,
        cheat: .none,
        hands: hands,
        support: support,
        width: width
    )
}

private struct Combination {
    let hands: Hands
    let support: Support
    let width: Width
    let expected: Variant
}

private let allTwelve: [Combination] = [
    Combination(hands: .palms, support: .toes, width: .normal, expected: .standard),
    Combination(hands: .palms, support: .toes, width: .wide, expected: .wide),
    Combination(hands: .palms, support: .toes, width: .narrow, expected: .narrow),
    Combination(hands: .palms, support: .knees, width: .normal, expected: .knee),
    Combination(hands: .palms, support: .knees, width: .wide, expected: .knee),
    Combination(hands: .palms, support: .knees, width: .narrow, expected: .knee),
    Combination(hands: .knuckles, support: .toes, width: .normal, expected: .knuckle),
    Combination(hands: .knuckles, support: .toes, width: .wide, expected: .knuckle),
    Combination(hands: .knuckles, support: .toes, width: .narrow, expected: .knuckle),
    Combination(hands: .knuckles, support: .knees, width: .normal, expected: .knuckleKnee),
    Combination(hands: .knuckles, support: .knees, width: .wide, expected: .knuckleKnee),
    Combination(hands: .knuckles, support: .knees, width: .narrow, expected: .knuckleKnee),
]

private let sessionJSONWithoutTechnique = """
{
  "schema": 2,
  "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
  "createdAt": "2026-07-04T09:30:15Z",
  "kind": "set",
  "trueReps": 4,
  "subject": "S01",
  "tags": {"lighting":"dim","distance":"far","clothing":"loose","tempo":"slow","variant":"knee","cheat":"none"},
  "notes": "",
  "device": {"model":"iPhone17,2","systemVersion":"26.0","appVersion":"1.0","appBuild":"1","poseModel":"pose_landmarker_full","cameraPosition":"front","featureVersion":"v1"},
  "frames": []
}
"""

@Suite("Technique tags")
struct TechniqueTagsTests {
    // MARK: - Raw values

    @Test("the new enums and variant use the documented raw values")
    func rawValues() throws {
        #expect(Hands.allCases.map(\.rawValue) == ["palms", "knuckles"])
        #expect(Support.allCases.map(\.rawValue) == ["toes", "knees"])
        #expect(Width.allCases.map(\.rawValue) == ["normal", "wide", "narrow"])
        #expect(Variant.knuckleKnee.rawValue == "knuckle_knee")
        #expect(Variant.allCases.map(\.rawValue) == ["standard", "knuckle", "knee", "knuckle_knee", "wide", "narrow", "na"])
        let decoded = try JSONDecoder().decode(Variant.self, from: Data(#""knuckle_knee""#.utf8))
        #expect(decoded == .knuckleKnee)
    }

    // MARK: - Summary

    @Test("the summary covers all twelve combinations")
    func summary() {
        for combination in allTwelve {
            let result = Tags.variant(hands: combination.hands, support: combination.support, width: combination.width)
            #expect(
                result == combination.expected,
                "\(combination.hands.rawValue), \(combination.support.rawValue), \(combination.width.rawValue)"
            )
        }
    }

    @Test("there are twelve combinations and every one is covered")
    func twelveCovered() {
        let all = Hands.allCases.flatMap { hands in
            Support.allCases.flatMap { support in Width.allCases.map { (hands, support, $0) } }
        }
        #expect(all.count == 12)
        #expect(allTwelve.count == 12)
        for (hands, support, width) in all {
            #expect(allTwelve.contains { $0.hands == hands && $0.support == support && $0.width == width })
        }
    }

    // MARK: - Resolved

    @Test("resolved infers the three from every legacy variant")
    func resolvedFromVariant() {
        let expected: [(Variant, Hands, Support, Width)] = [
            (.standard, .palms, .toes, .normal),
            (.knuckle, .knuckles, .toes, .normal),
            (.knee, .palms, .knees, .normal),
            (.knuckleKnee, .knuckles, .knees, .normal),
            (.wide, .palms, .toes, .wide),
            (.narrow, .palms, .toes, .narrow),
            (.na, .palms, .toes, .normal),
        ]
        #expect(expected.count == Variant.allCases.count)
        for (variant, hands, support, width) in expected {
            let resolved = tags(variant: variant).resolved
            #expect(resolved.hands == hands, "hands for \(variant.rawValue)")
            #expect(resolved.support == support, "support for \(variant.rawValue)")
            #expect(resolved.width == width, "width for \(variant.rawValue)")
        }
    }

    @Test("resolved returns the explicit fields when present, whatever the variant says")
    func resolvedExplicit() {
        let resolved = tags(variant: .standard, hands: .knuckles, support: .knees, width: .wide).resolved
        #expect(resolved.hands == .knuckles)
        #expect(resolved.support == .knees)
        #expect(resolved.width == .wide)
    }

    @Test("resolved fills only the missing fields from the variant")
    func resolvedPartial() {
        let resolved = tags(variant: .knee, hands: .knuckles).resolved
        #expect(resolved.hands == .knuckles)
        #expect(resolved.support == .knees)
        #expect(resolved.width == .normal)
    }

    @Test("summarising the resolved fields of a legacy variant returns that variant, na becomes standard")
    func summaryOfResolvedIsIdentity() {
        for variant in Variant.allCases {
            let resolved = tags(variant: variant).resolved
            let summary = Tags.variant(hands: resolved.hands, support: resolved.support, width: resolved.width)
            #expect(summary == (variant == .na ? .standard : variant), "round trip of \(variant.rawValue)")
        }
    }

    // MARK: - JSON

    @Test("explicit fields survive a round trip and are written under their own names")
    func roundTrip() throws {
        let original = tags(variant: .knuckleKnee, hands: .knuckles, support: .knees, width: .narrow)
        let data = try JSONEncoder().encode(original)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""hands":"knuckles""#))
        #expect(text.contains(#""support":"knees""#))
        #expect(text.contains(#""width":"narrow""#))
        #expect(text.contains(#""variant":"knuckle_knee""#))
        #expect(try JSONDecoder().decode(Tags.self, from: data) == original)
    }

    @Test("nil fields are omitted from the JSON")
    func nilOmitted() throws {
        let text = try #require(String(data: JSONEncoder().encode(tags(variant: .standard)), encoding: .utf8))
        #expect(!text.contains("hands"))
        #expect(!text.contains("support"))
        #expect(!text.contains("width"))
    }

    @Test("a session without the fields loads with all three nil and resolves from its variant")
    func oldFileDecodesToNil() throws {
        let session = try RecordedSession.decode(Data(sessionJSONWithoutTechnique.utf8))
        #expect(session.tags.hands == nil)
        #expect(session.tags.support == nil)
        #expect(session.tags.width == nil)
        #expect(session.tags.variant == .knee)
        let resolved = session.tags.resolved
        #expect(resolved.hands == .palms)
        #expect(resolved.support == .knees)
        #expect(resolved.width == .normal)
        // Writing it back adds nothing.
        let text = try #require(String(data: session.jsonData(), encoding: .utf8))
        #expect(!text.contains("\"hands\""))
    }

    @Test("a whole session keeps the fields through write and load")
    func sessionRoundTrip() throws {
        var session = try RecordedSession.decode(Data(sessionJSONWithoutTechnique.utf8))
        session.tags.hands = .knuckles
        session.tags.support = .knees
        session.tags.width = .wide
        session.tags.variant = Tags.variant(hands: .knuckles, support: .knees, width: .wide)
        let decoded = try RecordedSession.decode(session.jsonData())
        #expect(decoded == session)
        #expect(decoded.tags.variant == .knuckleKnee)
    }
}
