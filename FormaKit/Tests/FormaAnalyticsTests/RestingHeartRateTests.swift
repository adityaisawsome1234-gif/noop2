import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("Overnight resting heart rate")
struct RestingHeartRateTests {
    let t0 = Fixture.t0
    let m = Fixture.minute
    let h = Fixture.hour

    @Test func lowestEligibleFiveMinuteMean() throws {
        // 8 h at 60 bpm with a 30-min stretch alternating 51/52 bpm (time-weighted mean 51.5).
        let night = TimeRange(start: t0, end: t0 + 8 * h)
        let dipStart = t0 + 3 * h
        let samples = Fixture.hrRun(from: t0, count: Int(8 * h / 1_000)) { i in
            let t = t0 + Int64(i) * 1_000
            guard t >= dipStart, t < dipStart + 30 * m else { return 60 }
            return i % 2 == 0 ? 51 : 52
        }
        let result = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples)
        expectInvariants(result.restingHeartRate)
        #expect(result.restingHeartRate.value == 51.5)
        #expect(result.restingHeartRate.confidence == .high)
        #expect(result.restingHeartRate.specID == MetricID.overnightRestingHeartRate)
        #expect(result.restingHeartRate.inputs["label"] == RestingHeartRateEstimator.label)
        #expect(result.totalWindows == 476)        // starts every minute while start + 5 min ≤ end
        #expect(result.eligibleWindows == 476)
        let lowest = try #require(result.lowestWindow)
        #expect(lowest.start >= dipStart && lowest.end <= dipStart + 30 * m)
        #expect(result.coverage == 1.0)
    }

    @Test func roundsToOneDecimal() {
        let night = TimeRange(start: t0, end: t0 + 6 * h)
        let samples = Fixture.hrRun(from: t0, count: Int(6 * h / 1_000)) { [50, 51, 51][$0 % 3] }
        // Any 5-min window holds 100 complete 50/51/51 cycles: mean 50.666… → 50.7.
        #expect(RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples).restingHeartRate.value == 50.7)
    }

    @Test func windowsBelowEightyPercentCoverageAreNotEligible() {
        // 60 bpm at 1 Hz, except a 20-min stretch with one 40 bpm sample every 10 s (50 % coverage).
        // The lowest eligible window holds 3 min of 60 bpm and 2 min of sparse 40 bpm (exactly 80 %):
        // (60 × 180 s + 40 × 60 s) / 240 s = 55.0. A naive minimum would report 40.
        let night = TimeRange(start: t0, end: t0 + 6 * h)
        let sparseStart = t0 + 2 * h, sparseEnd = sparseStart + 20 * m
        var samples = Fixture.hrConstant(from: t0, to: sparseStart, bpm: 60)
        samples += Fixture.hrConstant(from: sparseStart, to: sparseEnd, bpm: 40, step: 10_000)
        samples += Fixture.hrConstant(from: sparseEnd, to: night.end, bpm: 60)
        let result = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples)
        #expect(result.restingHeartRate.value == 55.0)
        #expect(result.eligibleWindows < result.totalWindows)
    }

    @Test func longWindowNeedsThreeHoursOfCoveredHeartRate() {
        let night = TimeRange(start: t0, end: t0 + 8 * h)
        let samples = Fixture.hrConstant(from: t0, to: t0 + 150 * m, bpm: 55)   // 2 h 30 min (+ 4 s)
        let result = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples)
        expectInvariants(result.restingHeartRate)
        #expect(result.restingHeartRate.value == nil)
        #expect(result.restingHeartRate.availability
            == .insufficientData(detail: "Needs at least 3 h of overnight heart rate; have 2 h 30 min"))
        #expect(result.coveredMillis == 150 * m + 4_000)

        let enough = Fixture.hrConstant(from: t0, to: t0 + 180 * m, bpm: 55)
        #expect(RestingHeartRateEstimator.estimate(sleepWindow: night, samples: enough).restingHeartRate.value == 55.0)
    }

    @Test func shortWindowNeedsSixtyPercentCoverage() {
        let night = TimeRange(start: t0, end: t0 + 4 * h)
        let enough = Fixture.hrConstant(from: t0, to: t0 + 150 * m, bpm: 52)    // 62.5 %
        let ok = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: enough)
        #expect(ok.restingHeartRate.value == 52.0)
        #expect(ok.restingHeartRate.confidence == .low)   // follows coverage

        let half = Fixture.hrConstant(from: t0, to: t0 + 120 * m, bpm: 52)      // 50 %
        let low = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: half)
        expectInvariants(low.restingHeartRate)
        #expect(low.restingHeartRate.availability.isInsufficientData)
        #expect(low.restingHeartRate.availability.detailText.contains("60%"))
        #expect(low.restingHeartRate.availability.detailText.contains("have 50.0%"))
    }

    @Test func malformedOrTinyWindowsAndEmptyInput() {
        let samples = Fixture.hrConstant(from: t0, to: t0 + 8 * h, bpm: 55, step: 5_000)
        let cases: [TimeRange] = [
            TimeRange(start: t0, end: t0 + 4 * m),     // shorter than one window
            TimeRange(start: t0, end: t0),             // empty
            TimeRange(start: t0, end: t0 + 30 * h),    // longer than 24 h
            TimeRange(start: .min, end: .max),         // malformed
        ]
        for window in cases {
            let r = RestingHeartRateEstimator.estimate(sleepWindow: window, samples: samples)
            expectInvariants(r.restingHeartRate)
            #expect(r.restingHeartRate.value == nil, "window \(window)")
            #expect((r.coveredMillis == nil) == !(window.start > .min && !window.isEmpty), "window \(window)")
        }
        let night = TimeRange(start: t0, end: t0 + 8 * h)
        for input in [[], Fixture.hrRun(from: t0, count: 30_000) { _ in 10 }] {
            let r = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: input)
            #expect(r.restingHeartRate.availability.isInsufficientData)
            #expect(r.coveredMillis == 0)
        }
    }

    @Test func spottyCoverageEverywhereIsLowQuality() {
        // A sample every 7 s covers 5 of every 7 s (71 %): enough in total, but no window reaches 80 %.
        let night = TimeRange(start: t0, end: t0 + 6 * h)
        let samples = Fixture.hrConstant(from: t0, to: night.end, bpm: 55, step: 7_000)
        let result = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples)
        expectInvariants(result.restingHeartRate)
        #expect(result.restingHeartRate.availability.isLowQuality)
        #expect(result.eligibleWindows == 0)
    }

    @Test func invalidParametersAreRejectedWithoutLooping() {
        let night = TimeRange(start: t0, end: t0 + 8 * h)
        let samples = Fixture.hrConstant(from: t0, to: night.end, bpm: 55, step: 5_000)
        for p in [RestingHeartRateParameters(stepMillis: 0), RestingHeartRateParameters(windowMillis: -1),
                  RestingHeartRateParameters(minimumWindowCoverage: .nan)] {
            let r = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples, parameters: p)
            #expect(r.restingHeartRate.value == nil)
            expectInvariants(r.restingHeartRate)
        }
    }
}
