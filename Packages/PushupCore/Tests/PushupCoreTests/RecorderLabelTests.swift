import Foundation
import Testing
import PushupCore

private let device = DeviceInfo(
    model: "iPhone17,2",
    systemVersion: "26.0",
    appVersion: "1.0",
    appBuild: "1",
    poseModel: "pose_landmarker_full",
    cameraPosition: "front",
    featureVersion: PushupFeatureExtractor.featureVersion
)

private let tags = RecordedSession.Tags(
    lighting: .indoorBright,
    distance: .mid,
    clothing: .fitted,
    tempo: .normal,
    variant: .knuckle,
    cheat: .none
)

private func session(countVisible: Bool? = nil, editedAt: String? = nil) -> RecordedSession {
    RecordedSession(
        id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
        createdAt: "2026-07-04T09:30:15Z",
        kind: .set,
        trueReps: 8,
        poseLabel: nil,
        subject: "S07",
        tags: tags,
        notes: "",
        device: device,
        live: LiveResult(reps: 7, rejectedReps: 0, classifier: "heuristic"),
        frames: [],
        countVisible: countVisible,
        editedAt: editedAt
    )
}

@Suite("Recorder v3 labels")
struct RecorderLabelTests {
    // MARK: - Knuckle variant

    @Test("knuckle is a variant with that raw value, placed after standard")
    func knuckleVariant() throws {
        typealias V = RecordedSession.Tags.Variant
        #expect(V.knuckle.rawValue == "knuckle")
        #expect(V.allCases.prefix(2).map(\.rawValue) == ["standard", "knuckle"])
        let decoded = try JSONDecoder().decode(V.self, from: Data(#""knuckle""#.utf8))
        #expect(decoded == .knuckle)
    }

    // MARK: - countVisible and editedAt

    @Test("the new fields default to nil and are omitted from the JSON when nil")
    func newFieldsOmittedWhenNil() throws {
        let plain = session()
        #expect(plain.countVisible == nil)
        #expect(plain.editedAt == nil)
        let text = try #require(String(data: plain.jsonData(), encoding: .utf8))
        #expect(!text.contains("countVisible"))
        #expect(!text.contains("editedAt"))
        #expect(plain.schema == 2)
    }

    @Test("countVisible and editedAt survive JSON, including false", arguments: [true, false])
    func newFieldsRoundTrip(visible: Bool) throws {
        let original = session(countVisible: visible, editedAt: "2026-07-04T10:00:00Z")
        let data = try original.jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"countVisible\":\(visible)"))
        #expect(text.contains("\"editedAt\":\"2026-07-04T10:00:00Z\""))
        let decoded = try RecordedSession.decode(data)
        #expect(decoded == original)
        #expect(decoded.countVisible == visible)
        #expect(decoded.schema == RecordedSession.currentSchema)
    }

    @Test("an older file without the new fields still loads, and so does one with explicit nulls")
    func olderFileLoads() throws {
        let base = #"""
        {"schema":2,"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","createdAt":"2026-07-04T09:30:15Z",
         "kind":"set","trueReps":5,"subject":"S01",
         "tags":{"lighting":"dim","distance":"far","clothing":"loose","tempo":"slow","variant":"standard","cheat":"none"},
         "notes":"","device":{"model":"m","systemVersion":"26","appVersion":"1","appBuild":"1","poseModel":"p","cameraPosition":"front","featureVersion":"v1"},
         "frames":[]
        """#
        let old = try RecordedSession.decode(Data((base + "}").utf8))
        #expect(old.countVisible == nil)
        #expect(old.editedAt == nil)
        let nulls = try RecordedSession.decode(Data((base + #","countVisible":null,"editedAt":null}"#).utf8))
        #expect(nulls == old)
    }

    // MARK: - nextSubject

    @Test("nextSubject increments the trailing number and keeps its padding", arguments: [
        ("S01", "S02"),
        ("S09", "S10"),
        ("S10", "S11"),
        ("S99", "S100"),
        ("S099", "S100"),
        ("S001", "S002"),
        ("P7", "P8"),
        ("P9", "P10"),
        ("12", "13"),
        ("0", "1"),
        ("A1B2", "A1B3"),
        ("  S07  ", "S08"),
        ("S99999999999999999999999", "S100000000000000000000000"),
    ])
    func nextSubject(input: String, expected: String) {
        #expect(RecordedSession.nextSubject(after: input) == expected)
    }

    @Test("a label with no trailing digits gets a 2 appended", arguments: [
        ("Sam", "Sam2"),
        ("S01a", "S01a2"),
        ("", "2"),
        ("   ", "2"),
    ])
    func nextSubjectWithoutDigits(input: String, expected: String) {
        #expect(RecordedSession.nextSubject(after: input) == expected)
    }

    @Test("previousSubject steps back, keeps padding and stops at zero", arguments: [
        ("S02", "S01"),
        ("S10", "S09"),
        ("S100", "S099"),
        ("S1", "S0"),
        ("S01", "S00"),
        ("S00", "S00"),
        ("S0", "S0"),
        ("Sam", "Sam"),
    ])
    func previousSubject(input: String, expected: String) {
        #expect(RecordedSession.previousSubject(before: input) == expected)
    }

    @Test("stepping up then down returns to the start", arguments: ["S01", "S09", "S10", "S98", "S099"])
    func stepRoundTrip(start: String) {
        let up = RecordedSession.nextSubject(after: start)
        #expect(RecordedSession.previousSubject(before: up) == start)
    }
}
