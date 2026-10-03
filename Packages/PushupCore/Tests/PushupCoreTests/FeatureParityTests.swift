import CoreGraphics
import Foundation
import Testing
import PushupCore

/// One golden case exported by `training/tools/export_feature_fixtures.py`,
/// whose expected values come straight from `training/features.py`.
struct FeatureFixture: Decodable, CustomTestStringConvertible {
    let name: String
    let joints: [String: [Double]]
    let expected: [Double]?

    var testDescription: String { name }

    func poseJoints() throws -> [JointName: JointPoint] {
        var result: [JointName: JointPoint] = [:]
        for (key, value) in joints {
            let name = try #require(JointName(rawValue: key), "unknown joint name \(key)")
            #expect(value.count == 3)
            result[name] = JointPoint(x: CGFloat(value[0]), y: CGFloat(value[1]), confidence: Float(value[2]))
        }
        return result
    }

    static let all: [FeatureFixture] = {
        guard let url = Bundle.module.url(
            forResource: "feature_parity_v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ), let data = try? Data(contentsOf: url),
        let cases = try? JSONDecoder().decode([FeatureFixture].self, from: data) else {
            return []
        }
        return cases
    }()
}

@Suite("Swift/Python feature parity")
struct FeatureParityTests {
    private static let tolerance = 1e-4

    @Test("the fixture file loads and is broad enough")
    func fixtureCoverage() {
        let cases = FeatureFixture.all
        #expect(cases.count >= 60)
        #expect(cases.contains { $0.expected == nil })
        #expect(cases.contains { $0.expected != nil })
        #expect(Set(cases.map(\.name)).count == cases.count, "case names must be unique")
        for c in cases {
            if let expected = c.expected { #expect(expected.count == PushupFeatureExtractor.featureDim) }
        }
    }

    @Test("Swift extraction matches features.py", arguments: FeatureFixture.all)
    func matchesPython(_ fixture: FeatureFixture) throws {
        let swiftFeatures = PushupFeatureExtractor.extract(try fixture.poseJoints())
        switch (swiftFeatures, fixture.expected) {
        case (nil, nil):
            break
        case let (swift?, python?):
            #expect(swift.count == python.count)
            for (index, (s, p)) in zip(swift, python).enumerated() {
                #expect(abs(Double(s) - p) <= Self.tolerance, "feature \(index): swift \(s) vs python \(p)")
            }
        case (nil, .some):
            Issue.record("Swift returned nil but Python produced features")
        case (.some, nil):
            Issue.record("Swift produced features but Python returned None")
        }
    }

    @Test("report the largest element difference across all fixtures")
    func reportMaxDifference() throws {
        var maxDiff = 0.0
        var compared = 0
        for fixture in FeatureFixture.all {
            guard let python = fixture.expected,
                  let swift = PushupFeatureExtractor.extract(try fixture.poseJoints()) else { continue }
            compared += 1
            for (s, p) in zip(swift, python) { maxDiff = max(maxDiff, abs(Double(s) - p)) }
        }
        print("feature parity: \(FeatureFixture.all.count) cases (\(compared) with features), max abs element diff \(maxDiff)")
        #expect(maxDiff <= Self.tolerance)
    }
}
