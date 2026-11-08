import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("Workouts and training load")
struct WorkoutAndLoadTests {
    let t0 = Fixture.t0
    let m = Fixture.minute
    let hrMax200 = MaxHeartRate(bpm: 200, basis: .userOverride)

    /// Consecutive constant-HR blocks at 1 Hz: (minutes, bpm).
    func blocks(_ spec: [(Int64, Int)]) -> (samples: [HeartRateSample], range: TimeRange) {
        var samples: [HeartRateSample] = []
        var t = t0
        for (minutes, bpm) in spec {
            samples += Fixture.hrConstant(from: t, to: t + minutes * m, bpm: bpm)
            t += minutes * m
        }
        return (samples, TimeRange(start: t0, end: t))
    }

    @Test func workoutSummaryWithFullCoverage() throws {
        let (samples, range) = blocks([(5, 110), (5, 150)])
        let summary = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: HeartRateZones(maxHeartRate: hrMax200))
        #expect(summary.durationMillis == 600_000)
        #expect(summary.coverage == 1.0)
        #expect(summary.usableSampleCount == 600)
        #expect(summary.meanHeartRate.value == 130.0)
        #expect(summary.meanHeartRate.confidence == .high)
        #expect(summary.maxHeartRate.value == 150)
        let zones = try #require(summary.timeInZones.value)
        #expect(zones.millis == [0, 300_000, 0, 300_000, 0, 0])
        #expect(zones.millis(inZone: 3) == 300_000)
        #expect(zones.millis(inZone: 9) == nil)
        #expect(zones.totalMillis == 600_000)
        #expect(summary.timeInZones.confidence == .high)
        #expect(summary.edwardsTRIMP.value == 20.0)   // 5 × 1 + 5 × 3
        for v in [summary.meanHeartRate, summary.edwardsTRIMP] { expectInvariants(v) }
        expectInvariants(summary.maxHeartRate)
        expectInvariants(summary.timeInZones)
        #expect(summary.meanHeartRate.specID == MetricID.workoutSummary)
        #expect(summary.timeInZones.specID == MetricID.heartRateZones)
        #expect(summary.edwardsTRIMP.specID == MetricID.edwardsLoad)
    }

    @Test func coverageBelowHalfWithholdsEveryOptionalValue() {
        // 240 samples at 1 Hz in a 10-min workout: 239 s + a final 5 s span = 244 s ≈ 41 %.
        let samples = Fixture.hrRun(from: t0, count: 240) { _ in 140 }
        let range = TimeRange(start: t0, end: t0 + 10 * m)
        let summary = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: HeartRateZones(maxHeartRate: hrMax200))
        #expect(summary.coverage == 244.0 / 600.0)
        #expect(summary.meanHeartRate.value == nil)
        #expect(summary.maxHeartRate.value == nil)
        #expect(summary.timeInZones.value == nil)
        #expect(summary.edwardsTRIMP.value == nil)
        #expect(summary.meanHeartRate.availability.isLowQuality)
        #expect(summary.edwardsTRIMP.availability.isLowQuality)
        #expect(summary.meanHeartRate.availability.detailText.contains("50%"))
        #expect(summary.meanHeartRate.coverage == 244.0 / 600.0)
        expectInvariants(summary.meanHeartRate)
        expectInvariants(summary.maxHeartRate)
        // The zone bounds themselves are still known.
        #expect(summary.zoneThresholds.value != nil)
    }

    @Test func exactlyHalfCoverageIsEnough() {
        // 296 samples: 295 s + 5 s = 300 s of a 600 s workout.
        let samples = Fixture.hrRun(from: t0, count: 296) { _ in 140 }
        let summary = WorkoutAnalyzer.summarize(range: TimeRange(start: t0, end: t0 + 10 * m), samples: samples,
                                                zones: HeartRateZones(maxHeartRate: hrMax200))
        #expect(summary.coverage == 0.5)
        #expect(summary.meanHeartRate.value == 140)
        #expect(summary.meanHeartRate.confidence == .low)
    }

    @Test func noUsableSamplesIsInsufficientData() {
        let range = TimeRange(start: t0, end: t0 + 10 * m)
        let invalid = Fixture.hrRun(from: t0, count: 600) { _ in 300 }
        for samples in [[], invalid] {
            let summary = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: HeartRateZones(maxHeartRate: hrMax200))
            #expect(summary.coverage == 0)
            #expect(summary.usableSampleCount == 0)
            #expect(summary.meanHeartRate.availability.isInsufficientData)
            #expect(summary.maxHeartRate.availability.isInsufficientData)
            #expect(summary.timeInZones.availability.isInsufficientData)
            #expect(summary.edwardsTRIMP.availability.isInsufficientData)
            expectInvariants(summary.maxHeartRate)
        }
    }

    @Test func emptyOrMalformedWorkoutRange() {
        let empty = WorkoutAnalyzer.summarize(range: TimeRange(start: t0, end: t0), samples: [Fixture.hr(t0, 100)],
                                              zones: HeartRateZones(maxHeartRate: hrMax200))
        #expect(empty.durationMillis == 0)
        #expect(empty.coverage == nil)
        #expect(empty.meanHeartRate.value == nil)
        let malformed = WorkoutAnalyzer.summarize(range: TimeRange(start: .min, end: .max), samples: [Fixture.hr(t0, 100)],
                                                  zones: HeartRateZones(maxHeartRate: hrMax200))
        #expect(malformed.durationMillis == nil)
        #expect(malformed.edwardsTRIMP.value == nil)
        expectInvariants(malformed.edwardsTRIMP)
    }

    @Test func missingHRmaxKeepsMeanAndMaxButNotZonesOrLoad() {
        let (samples, range) = blocks([(10, 120)])
        let summary = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: HeartRateZones(maxHeartRate: nil))
        #expect(summary.meanHeartRate.value == 120)
        #expect(summary.maxHeartRate.value == 120)
        #expect(summary.timeInZones.availability == .insufficientData(detail: "Set your max heart rate or birth year"))
        #expect(summary.edwardsTRIMP.availability == .insufficientData(detail: "Set your max heart rate or birth year"))
        expectInvariants(summary.timeInZones)
    }

    @Test func ageEstimatedHRmaxCapsZoneAndLoadConfidence() {
        let (samples, range) = blocks([(10, 120)])
        let zones = HeartRateZones(maxHeartRate: MaxHeartRate(bpm: 182.8, basis: .estimatedFromAge, ageYears: 36))
        let summary = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: zones)
        #expect(summary.meanHeartRate.confidence == .high)
        #expect(summary.timeInZones.confidence == .moderate)
        #expect(summary.edwardsTRIMP.confidence == .moderate)
    }

    @Test func edwardsTRIMPHandExample() {
        // HRmax 200: 110 bpm = 55 % (w1), 150 = 75 % (w3), 185 = 92.5 % (w5),
        // 120 = exactly 60 % (w2, inclusive lower bound), 90 = 45 % (w0).
        let (samples, range) = blocks([(10, 110), (10, 150), (5, 185), (2, 120), (3, 90)])
        let load = TrainingLoad.workoutLoad(range: range, samples: samples, hrMax: hrMax200)
        expectInvariants(load)
        #expect(load.value == 69.0)   // 10×1 + 10×3 + 5×5 + 2×2 + 3×0
        #expect(load.coverage == 1.0)
        #expect(load.inputs["minutesByBand"] == "50–60%: 10.0 min, 60–70%: 2.0 min, 70–80%: 10.0 min, 80–90%: 0.0 min, ≥90%: 5.0 min")
    }

    @Test func edwardsBandsIgnoreTheDisplayedZoneModel() {
        let (samples, range) = blocks([(10, 150)])
        let reserve = HeartRateZones(model: .heartRateReserve, maxHeartRate: hrMax200, restingHeartRate: 60)
        let summary = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: reserve)
        #expect(summary.edwardsTRIMP.value == 30.0)                 // 75 % HRmax → weight 3
        #expect(summary.timeInZones.value?.millis(inZone: 2) == 600_000) // 150 is in HRR zone 2 (144–158)
    }

    @Test func dailyLoadNeedsThirtyPercentCoverage() {
        let day = LocalDay(year: 2026, month: 1, day: 5)
        // 25 924 s covered (25 920 samples at 1 Hz: 25 919 s + a final 5 s span) of 86 400 s ≥ 30 %.
        let enough = Fixture.hrRun(from: t0, count: 25_920) { _ in 110 }
        let load = TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: enough, hrMax: hrMax200)
        expectInvariants(load)
        #expect(load.value == 432.1)  // 25 924 s / 60 × weight 1
        #expect(load.window == TimeRange(start: t0, end: t0 + 24 * Fixture.hour))

        let tooLittle = Fixture.hrRun(from: t0, count: 25_000) { _ in 110 }
        let low = TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: tooLittle, hrMax: hrMax200)
        expectInvariants(low)
        #expect(low.value == nil)
        #expect(low.availability.isLowQuality)
        #expect(low.availability.detailText.contains("30%"))

        let noMax = TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: enough, hrMax: nil)
        #expect(noMax.availability == .insufficientData(detail: "Set your max heart rate or birth year"))
        expectInvariants(noMax)

        let empty = TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: [], hrMax: hrMax200)
        #expect(empty.availability.isInsufficientData)
        let invalidDay = TrainingLoad.dailyLoad(day: LocalDay(year: 2026, month: 2, day: 30), calendar: Fixture.utc,
                                                samples: enough, hrMax: hrMax200)
        #expect(invalidDay.value == nil)
    }

    @Test func dailyLoadUsesTheLocalDayOfTheCalendar() throws {
        let berlin = try #require(Fixture.calendar("Europe/Berlin"))
        // Berlin's 2026-01-05 starts at 2026-01-04T23:00Z.
        let samples = Fixture.hrRun(from: t0 - Fixture.hour, count: 30_000) { _ in 110 }
        let load = TrainingLoad.dailyLoad(day: LocalDay(year: 2026, month: 1, day: 5), calendar: berlin, samples: samples,
                                          hrMax: hrMax200)
        #expect(load.window == TimeRange(start: t0 - Fixture.hour, end: t0 + 23 * Fixture.hour))
        #expect(load.value == 500.1)   // 30 004 s / 60
    }

    @Test func banisterNeedsSexRestAndMaxAndNeverAssumesSex() {
        let (samples, range) = blocks([(30, 130)])   // x = (130 − 60) / (200 − 60) = 0.5
        let male = TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax200, restingHeartRate: 60, sex: .male)
        let female = TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax200, restingHeartRate: 60, sex: .female)
        #expect(male.value == 25.1)     // 30 × 0.5 × 0.64 × e^0.96 = 25.07
        #expect(female.value == 29.7)   // 30 × 0.5 × 0.86 × e^0.835 = 29.73
        expectInvariants(male)
        #expect(male.specID == MetricID.banisterTRIMP)

        let unspecified = TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax200, restingHeartRate: 60,
                                                     sex: .unspecified)
        #expect(unspecified.value == nil)
        #expect(unspecified.availability == .insufficientData(detail: TrainingLoad.missingSexDetail))
        let noRest = TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax200, restingHeartRate: nil, sex: .male)
        #expect(noRest.availability == .insufficientData(detail: TrainingLoad.missingRestingDetail))
        let noMax = TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: nil, restingHeartRate: 60, sex: .male)
        #expect(noMax.availability == .insufficientData(detail: MaxHeartRateResolver.missingInputDetail))
        for v in [unspecified, noRest, noMax] { expectInvariants(v) }
    }

    @Test func banisterClampsHeartRateReserveToZeroAndOne() {
        let (samples, range) = blocks([(10, 50), (10, 230)])   // x clamps to 0, then to 1
        let male = TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax200, restingHeartRate: 60, sex: .male)
        #expect(male.value == 43.7)   // 10 × 1 × 0.64 × e^1.92 = 43.65
    }
}
