import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("Readiness (experimental)")
struct ReadinessTests {
    let day = LocalDay(year: 2026, month: 2, day: 10)
    let cal = Fixture.utc

    /// `nights` constant values on the nights before `day`, plus `target` on `day` itself.
    func history(_ value: Double, nights: Int, target: Double?) -> [LocalDay: Double?] {
        var out = dailyValues(endingOn: day.adding(days: -1, calendar: cal), count: nights) { _ in value }
        if let target { out[day] = target }
        return out
    }

    func compute(hrv: [LocalDay: Double?], rhr: [LocalDay: Double?] = [:], sleep: [LocalDay: Double?] = [:],
                 parameters: ReadinessParameters = .default) -> ReadinessResult {
        ReadinessCalculator.compute(day: day, calendar: cal, lnRMSSD: hrv, restingHeartRate: rhr,
                                    sleepDurationMinutes: sleep, parameters: parameters)
    }

    @Test func calibratingUntilFourteenHRVNights() throws {
        let r = compute(hrv: history(4.0, nights: 13, target: 4.1))
        expectInvariants(r.composite)
        #expect(r.composite.value == nil)
        #expect(r.band == nil)
        #expect(r.composite.availability == .calibrating(have: 13, need: 14, unit: "nights"))
        let hrv = try #require(r.component(.hrv))
        #expect(hrv.calibrationHave == 13)
        #expect(hrv.calibrationNeed == 14)
        #expect(!hrv.isIncluded)

        let ready = compute(hrv: history(4.0, nights: 14, target: 4.1))
        #expect(ready.composite.value == 2.0)
        #expect(ready.component(.hrv)?.calibrationHave == 14)
    }

    @Test func bandThresholdsAreInclusiveOfOneSD() {
        // Constant history → SD 0 → floor 0.05, so z = (x − 4.0) / 0.05.
        let cases: [(Double, Double, ReadinessBand)] = [
            (3.95, -1.0, .withinUsual), (3.9495, -1.01, .belowUsual),
            (4.05, 1.0, .withinUsual), (4.0505, 1.01, .aboveUsual), (4.0, 0, .withinUsual),
        ]
        for (target, z, band) in cases {
            let r = compute(hrv: history(4.0, nights: 20, target: target))
            expectInvariants(r.composite)
            #expect(r.composite.value == z, "target \(target)")
            #expect(r.band == band, "target \(target)")
        }
        #expect(ReadinessCalculator.band(for: -1.0) == .withinUsual)
        #expect(ReadinessCalculator.band(for: -1.000001) == .belowUsual)
        #expect(ReadinessBand.belowUsual.label == "below usual")
        #expect(ReadinessBand.withinUsual.label == "within usual")
        #expect(ReadinessBand.aboveUsual.label == "above usual")
    }

    @Test func compositeIsWeightedOverAvailableComponents() throws {
        // Floors apply (constant histories): HRV z = 0.1 / 0.05 = 2; RHR raw (52 − 50) / 1 = 2, inverted → −2;
        // sleep (450 − 420) / 30 = 1. Composite = (0.5·2 + 0.3·(−2) + 0.2·1) / 1.0 = 0.6.
        let r = compute(hrv: history(4.0, nights: 20, target: 4.1), rhr: history(50, nights: 20, target: 52),
                        sleep: history(420, nights: 20, target: 450))
        expectInvariants(r.composite)
        #expect(r.composite.value == 0.6)
        #expect(r.band == .withinUsual)
        #expect(r.composite.coverage == 1.0)
        #expect(r.composite.confidence == .moderate)     // all three, but only 20 HRV nights (< 21)
        #expect(r.weights == ReadinessWeights(hrv: 0.5, restingHeartRate: 0.3, sleepDuration: 0.2))
        let rhr = try #require(r.component(.restingHeartRate))
        #expect(rhr.z == -2)
        #expect(rhr.signInverted)
        #expect(rhr.standardDeviationUsed == 1.0)
        #expect(rhr.baseline.value?.mean == 50)
        #expect(rhr.baseline.value?.n == 20)
        #expect(rhr.weight == 0.3)
        #expect(r.component(.sleepDuration)?.z == 1)
        #expect(r.component(.hrv)?.z == 2)
        #expect(r.composite.unitlessStatus == "SD")

        // Without sleep: (0.5·2 + 0.3·(−2)) / 0.8 = 0.5; coverage 0.8.
        let noSleep = compute(hrv: history(4.0, nights: 20, target: 4.1), rhr: history(50, nights: 20, target: 52))
        #expect(noSleep.composite.value == 0.5)
        #expect(noSleep.composite.coverage == 0.8)
        #expect(noSleep.component(.sleepDuration)?.availability == .insufficientData(detail: "No confirmed sleep duration for this night"))

        // HRV only: composite = z_HRV, low confidence.
        let hrvOnly = compute(hrv: history(4.0, nights: 25, target: 4.1))
        #expect(hrvOnly.composite.value == 2.0)
        #expect(hrvOnly.composite.confidence == .low)
        #expect(hrvOnly.band == .aboveUsual)

        // All three with ≥ 21 HRV nights: high confidence.
        let mature = compute(hrv: history(4.0, nights: 21, target: 4.1), rhr: history(50, nights: 21, target: 52),
                             sleep: history(420, nights: 21, target: 450))
        #expect(mature.composite.confidence == .high)
    }

    @Test func lowerRestingHeartRateThanUsualIsPositive() {
        let r = compute(hrv: history(4.0, nights: 20, target: 4.0), rhr: history(50, nights: 20, target: 48))
        #expect(r.component(.restingHeartRate)?.z == 2)
        #expect(r.composite.value == 0.75)   // (0.5·0 + 0.3·2) / 0.8
    }

    @Test func realBaselineSDIsUsedWhenAboveTheFloor() throws {
        // Alternating 3.9 / 4.1 for 20 nights: mean 4.0, sample SD = 0.1 × √(20/19).
        var hrv = dailyValues(endingOn: day.adding(days: -1, calendar: cal), count: 20) { $0 % 2 == 0 ? 3.9 : 4.1 }
        hrv[day] = 4.2
        let r = compute(hrv: hrv)
        let c = try #require(r.component(.hrv))
        let sd = 0.1 * (20.0 / 19.0).squareRoot()
        #expect(abs((c.standardDeviationUsed ?? 0) - sd) < 1e-9)
        #expect(c.z == ((4.2 - 4.0) / sd * 100).rounded() / 100)
    }

    @Test func missingTargetHRVMakesTheCompositeUnavailable() {
        let r = compute(hrv: history(4.0, nights: 20, target: nil), rhr: history(50, nights: 20, target: 45),
                        sleep: history(420, nights: 20, target: 480))
        expectInvariants(r.composite)
        #expect(r.composite.value == nil)
        #expect(r.band == nil)
        #expect(r.composite.availability == .insufficientData(detail: "No overnight HRV for this night"))
        #expect(r.component(.restingHeartRate)?.isIncluded == true)   // still reported for transparency
    }

    @Test func sleepNeedsSevenNights() {
        let r = compute(hrv: history(4.0, nights: 20, target: 4.1), rhr: history(50, nights: 20, target: 52),
                        sleep: history(420, nights: 6, target: 450))
        #expect(r.component(.sleepDuration)?.availability == .calibrating(have: 6, need: 7, unit: "nights"))
        #expect(r.component(.sleepDuration)?.calibrationHave == 6)
        #expect(r.composite.value == 0.5)
    }

    @Test func invalidParametersAndDaysAreRejected() {
        let zeroHRVWeight = ReadinessParameters(weights: ReadinessWeights(hrv: 0, restingHeartRate: 0.5, sleepDuration: 0.5))
        let r = compute(hrv: history(4.0, nights: 20, target: 4.1), parameters: zeroHRVWeight)
        #expect(r.composite.value == nil)
        expectInvariants(r.composite)
        let badDay = ReadinessCalculator.compute(day: LocalDay(year: 2026, month: 2, day: 30), calendar: cal,
                                                 lnRMSSD: [:], restingHeartRate: [:], sleepDurationMinutes: [:])
        #expect(badDay.composite.value == nil)
        expectInvariants(badDay.composite)
    }

    @Test func resultTextGivesNoAdvice() {
        let r = compute(hrv: history(4.0, nights: 20, target: 3.5), rhr: history(50, nights: 20, target: 60),
                        sleep: history(420, nights: 20, target: 300))
        #expect(r.band == .belowUsual)
        let text = (Array(r.composite.inputs.values) + r.components.map { $0.availability.explanation }).joined(separator: " ").lowercased()
        for word in ["should", "recommend", "advise", "take it easy", "train", "rest day", "push"] {
            #expect(!text.contains(word), "\(word)")
        }
    }
}

private extension MetricValue {
    /// The catalog unit for this value's spec, used to check the composite is reported in SD units.
    var unitlessStatus: String {
        (MetricCatalog.spec(for: specID)?.unit ?? "").components(separatedBy: " ").first ?? ""
    }
}
