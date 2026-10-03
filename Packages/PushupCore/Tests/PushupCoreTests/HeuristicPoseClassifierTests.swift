import Foundation
import Testing
import PushupCore

@Suite("HeuristicPoseClassifier")
struct HeuristicPoseClassifierTests {
    /// 25-length feature vector with the two elbow angles (radians) set.
    private func features(leftRadians: Float, rightRadians: Float) -> [Float] {
        var v = [Float](repeating: 0, count: PushupFeatureExtractor.featureDim)
        v[PushupFeatureExtractor.leftElbowAngleIndex] = leftRadians
        v[PushupFeatureExtractor.rightElbowAngleIndex] = rightRadians
        return v
    }

    /// The classifier's own radians-to-degrees conversion.
    private func degrees(fromRadians r: Float) -> Float { r * 180 / .pi }

    /// Left/right radian values whose mean, under the classifier's own
    /// conversion and averaging, is exactly `degrees` in Float. A single
    /// radian value cannot always hit a degree value exactly (the float grid
    /// is coarser in radians than in degrees near 145), so this searches
    /// pairs a few float steps either side of the nominal value.
    private func exactPair(forDegrees degrees: Float) -> (left: Float, right: Float)? {
        let guess = degrees * .pi / 180
        var steps: [Float] = [guess]
        var up = guess, down = guess
        for _ in 0..<4 {
            up = up.nextUp
            down = down.nextDown
            steps += [up, down]
        }
        for l in steps {
            for r in steps where (self.degrees(fromRadians: l) + self.degrees(fromRadians: r)) / 2 == degrees {
                return (l, r)
            }
        }
        return nil
    }

    private func features(degrees: Float) -> [Float] {
        let pair = exactPair(forDegrees: degrees) ?? (degrees * .pi / 180, degrees * .pi / 180)
        return features(leftRadians: pair.left, rightRadians: pair.right)
    }

    /// Both elbows at the nearest radian value whose degrees are strictly
    /// below / above `degrees` under the classifier's conversion.
    private func features(justBelow degrees: Float) -> [Float] {
        var r = degrees * .pi / 180
        while self.degrees(fromRadians: r) >= degrees { r = r.nextDown }
        return features(leftRadians: r, rightRadians: r)
    }

    private func features(justAbove degrees: Float) -> [Float] {
        var r = degrees * .pi / 180
        while self.degrees(fromRadians: r) <= degrees { r = r.nextUp }
        return features(leftRadians: r, rightRadians: r)
    }

    @Test("the helper really builds inputs whose mean is exactly the boundary degrees")
    func helperIsExact() throws {
        for degrees: Float in [120, 145] {
            let pair = try #require(exactPair(forDegrees: degrees))
            #expect((self.degrees(fromRadians: pair.left) + self.degrees(fromRadians: pair.right)) / 2 == degrees)
        }
    }

    @Test("the elbow angle indices match the documented feature layout")
    func elbowIndices() {
        #expect(PushupFeatureExtractor.leftElbowAngleIndex == 20)
        #expect(PushupFeatureExtractor.rightElbowAngleIndex == 21)
        #expect(PushupFeatureExtractor.featureDim == 25)
    }

    @Test("mean elbow angle below 120 degrees is a confident down", arguments: [30, 80, 100, 119] as [Float])
    func belowDownThreshold(_ degrees: Float) {
        let result = HeuristicPoseClassifier().classify(features(degrees: degrees))
        #expect(result.label == .down)
        #expect(result.confidence == 0.9)
    }

    @Test("mean elbow angle above 145 degrees is a confident up", arguments: [146, 160, 170, 180] as [Float])
    func aboveUpThreshold(_ degrees: Float) {
        let result = HeuristicPoseClassifier().classify(features(degrees: degrees))
        #expect(result.label == .up)
        #expect(result.confidence == 0.9)
    }

    @Test("the middle band returns notPushup at 0.35 before any confident frame", arguments: [121, 130, 144] as [Float])
    func middleBandBeforeAnyConfidentFrame(_ degrees: Float) {
        let result = HeuristicPoseClassifier().classify(features(degrees: degrees))
        #expect(result.label == .notPushup)
        #expect(result.confidence == 0.35)
    }

    @Test("the middle band continues the previous confident label at 0.35")
    func middleBandContinuesPreviousLabel() {
        let classifier = HeuristicPoseClassifier()

        _ = classifier.classify(features(degrees: 90))
        let afterDown = classifier.classify(features(degrees: 130))
        #expect(afterDown.label == .down)
        #expect(afterDown.confidence == 0.35)

        _ = classifier.classify(features(degrees: 170))
        let afterUp = classifier.classify(features(degrees: 130))
        #expect(afterUp.label == .up)
        #expect(afterUp.confidence == 0.35)

        // Staying in the band keeps the same label.
        let again = classifier.classify(features(degrees: 140))
        #expect(again.label == .up)
        #expect(again.confidence == 0.35)
    }

    @Test("exactly 120 and exactly 145 degrees fall in the middle band (strict inequalities)")
    func boundariesAreInTheMiddleBand() {
        let classifier = HeuristicPoseClassifier()
        _ = classifier.classify(features(degrees: 170))

        let atDown = classifier.classify(features(degrees: 120))
        #expect(atDown.label == .up)
        #expect(atDown.confidence == 0.35)

        _ = classifier.classify(features(degrees: 90))
        let atUp = classifier.classify(features(degrees: 145))
        #expect(atUp.label == .down)
        #expect(atUp.confidence == 0.35)
    }

    @Test("one float step past each boundary is confident")
    func justPastBoundaries() {
        #expect(HeuristicPoseClassifier().classify(features(justBelow: 120)).label == .down)
        #expect(HeuristicPoseClassifier().classify(features(justAbove: 145)).label == .up)
    }

    @Test("the two elbows are averaged")
    func elbowsAreAveraged() {
        let classifier = HeuristicPoseClassifier()
        // Mean 100: down, even though one arm alone would read up.
        let down = classifier.classify(features(leftRadians: Float(50) * .pi / 180, rightRadians: Float(150) * .pi / 180))
        #expect(down.label == .down)
        // Mean 160: up.
        let up = classifier.classify(features(leftRadians: Float(170) * .pi / 180, rightRadians: Float(150) * .pi / 180))
        #expect(up.label == .up)
    }

    @Test("wrong-length input gives notPushup at zero confidence", arguments: [0, 1, 24, 26, 100])
    func wrongLength(_ count: Int) {
        let result = HeuristicPoseClassifier().classify([Float](repeating: 0, count: count))
        #expect(result.label == .notPushup)
        #expect(result.confidence == 0)
    }

    @Test("wrong-length input does not disturb the remembered label")
    func wrongLengthKeepsState() {
        let classifier = HeuristicPoseClassifier()
        _ = classifier.classify(features(degrees: 170))
        _ = classifier.classify([1, 2, 3])
        #expect(classifier.classify(features(degrees: 130)).label == .up)
    }

    @Test("custom thresholds and scores are honoured")
    func customConfig() {
        let config = HeuristicPoseClassifier.Config(
            downElbowDegrees: 90,
            upElbowDegrees: 170,
            confidentScore: 0.8,
            ambiguousScore: 0.2
        )
        let classifier = HeuristicPoseClassifier(config: config)

        // 110 degrees is down under the defaults but in the middle band here.
        let middle = classifier.classify(features(degrees: 110))
        #expect(middle.label == .notPushup)
        #expect(middle.confidence == 0.2)

        let down = classifier.classify(features(degrees: 80))
        #expect(down.label == .down)
        #expect(down.confidence == 0.8)

        // 160 degrees is up under the defaults but in the middle band here.
        let stillDown = classifier.classify(features(degrees: 160))
        #expect(stillDown.label == .down)
        #expect(stillDown.confidence == 0.2)

        let up = classifier.classify(features(degrees: 175))
        #expect(up.label == .up)
        #expect(up.confidence == 0.8)
    }

    @Test("default Config matches the shipped thresholds")
    func defaultConfig() {
        let config = HeuristicPoseClassifier.Config.default
        #expect(config.downElbowDegrees == 120)
        #expect(config.upElbowDegrees == 145)
        #expect(config.confidentScore == 0.9)
        #expect(config.ambiguousScore == 0.35)
        #expect(HeuristicPoseClassifier.Config() == .default)
    }

    @Test("PoseLabel raw values match training/dataset.py")
    func labelRawValues() {
        #expect(PoseLabel.up.rawValue == "up")
        #expect(PoseLabel.down.rawValue == "down")
        #expect(PoseLabel.notPushup.rawValue == "not_pushup")
    }
}
