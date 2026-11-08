import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("Honesty invariants and robustness")
struct InvariantTests {
    let t0 = Fixture.t0
    let h = Fixture.hour

    func expectUnavailable<V>(_ m: MetricValue<V>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!m.availability.isAvailable, sourceLocation: sourceLocation)
        #expect(m.value == nil, sourceLocation: sourceLocation)
        #expect(m.confidence == .none, sourceLocation: sourceLocation)
        expectInvariants(m, sourceLocation: sourceLocation)
    }

    /// With no input at all, every analyzer reports nil values with a reason and `.none` confidence.
    @Test func emptyInputNeverProducesZeroOrConfidence() {
        let night = TimeRange(start: t0, end: t0 + 8 * h)
        let day = LocalDay(year: 2026, month: 1, day: 5)
        let hrMax = MaxHeartRate(bpm: 190, basis: .userOverride)

        expectUnavailable(HeartRateSeries([]).summary(in: night))
        let w = WorkoutAnalyzer.summarize(range: night, samples: [], zones: HeartRateZones(maxHeartRate: hrMax))
        expectUnavailable(w.meanHeartRate)
        expectUnavailable(w.maxHeartRate)
        expectUnavailable(w.timeInZones)
        expectUnavailable(w.edwardsTRIMP)
        expectUnavailable(TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: [], hrMax: hrMax))
        expectUnavailable(TrainingLoad.banisterTRIMP(range: night, samples: [], hrMax: hrMax, restingHeartRate: 50, sex: .female))
        expectUnavailable(RestingHeartRateEstimator.estimate(sleepWindow: night, samples: []).restingHeartRate)
        let hrv = HRVAnalyzer.analyze(beats: [], range: night)
        expectUnavailable(hrv.rmssd)
        expectUnavailable(hrv.lnRMSSD)
        expectUnavailable(hrv.rawRMSSD)
        #expect(hrv.acceptedFraction == nil)
        expectUnavailable(SleepDetector.detect(nightEndingOn: day, calendar: Fixture.utc, motion: nil))
        expectUnavailable(SleepDetector.detect(nightEndingOn: day, calendar: Fixture.utc, motion: []))
        let s = SleepSummary.fromConfirmedWindow(night, motion: nil, heartRate: nil)
        expectUnavailable(s.wakeDuration)
        expectUnavailable(s.sleepDurationEstimate)
        expectUnavailable(s.continuity)
        expectUnavailable(s.meanHeartRate)
        for period in TrendPeriod.allCases {
            expectUnavailable(TrendAnalyzer.summary(of: [:], period: period, endingOn: day, calendar: Fixture.utc).statistics)
        }
        expectUnavailable(TrendAnalyzer.recentVersusPrior(of: [:], endingOn: day, calendar: Fixture.utc))
        expectUnavailable(BaselineCalculator.baseline(values: [:], targetDay: day, calendar: Fixture.utc))
        let readiness = ReadinessCalculator.compute(day: day, calendar: Fixture.utc, lnRMSSD: [:], restingHeartRate: [:],
                                                    sleepDurationMinutes: [:])
        expectUnavailable(readiness.composite)
        #expect(readiness.band == nil)
        for c in readiness.components {
            #expect(c.z == nil)
            #expect(!c.isIncluded)
            expectUnavailable(c.baseline)
        }
        expectUnavailable(MaxHeartRateResolver.resolve(profile: UserProfile(), asOf: t0, calendar: Fixture.utc))
        expectUnavailable(HeartRateZones(maxHeartRate: nil).thresholds())
    }

    @Test func resultsAreDeterministic() {
        let samples = Fixture.hrRun(from: t0, count: 20_000, step: 1_000) { 50 + ($0 * 7919) % 40 }
        let night = TimeRange(start: t0, end: t0 + 6 * h)
        let a = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples)
        let b = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples.reversed())
        #expect(a == b)
        let zones = HeartRateZones(maxHeartRate: MaxHeartRate(bpm: 190, basis: .userOverride))
        #expect(WorkoutAnalyzer.summarize(range: night, samples: samples, zones: zones)
            == WorkoutAnalyzer.summarize(range: night, samples: samples.reversed(), zones: zones))
    }

    /// Seeded random garbage (extreme timestamps, NaN/∞ values, bad flags, absurd parameters) must never
    /// crash, and every result must still satisfy the invariants.
    @Test(arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func randomisedMalformedInputsNeverCrash(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        func pick<T>(_ xs: [T]) -> T { xs[Int.random(in: 0..<xs.count, using: &rng)] }
        func timestamp() -> EpochMillis {
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: return .max
            case 1: return .min
            case 2: return Int64.random(in: .min ... .max, using: &rng)
            default: return t0 + Int64.random(in: -2 * h ... 30 * h, using: &rng)
            }
        }
        func number() -> Double {
            pick([Double.nan, .infinity, -.infinity, -1, 0, .greatestFiniteMagnitude, Double.random(in: 0...3_000, using: &rng),
                  Double.random(in: 300...1_500, using: &rng), Double.random(in: 300...1_500, using: &rng)])
        }
        func range() -> TimeRange {
            pick([TimeRange(start: .min, end: .max), TimeRange(start: t0, end: t0),
                  TimeRange(start: t0 + Int64.random(in: 0...h, using: &rng), end: t0 + Int64.random(in: 0...26 * h, using: &rng)),
                  TimeRange(start: timestamp(), end: timestamp())])
        }
        let flags: [QualityFlags] = [[], [], [], .outOfRange, .noSensorContact, .deviceMarkedInvalid, .clockUnmapped,
                                     .phoneReceiveTime, .nearClockDiscontinuity, [.outOfRange, .unvalidatedField]]
        let sources = MeasurementSource.allCases

        let hr = (0..<3_000).map { _ in
            HeartRateSample(deviceID: pick(["a", "b"]), timestamp: timestamp(),
                            bpm: Int.random(in: 0..<25, using: &rng) == 0 ? Int.random(in: .min ... .max, using: &rng)
                                : Int.random(in: 20...250, using: &rng),
                            source: pick(sources), receivedAt: timestamp(), quality: pick(flags))
        }
        let beats = (0..<3_000).map { i in
            BeatInterval(deviceID: pick(["a", "b"]), timestamp: timestamp(), intervalMillis: number(), source: pick(sources),
                         recordKey: Int64(i), indexInRecord: i, receivedAt: timestamp(), timingBasis: .reconstructedFromRecordTime,
                         quality: pick(flags))
        }
        let motion = (0..<3_000).map { _ in
            MotionEpoch(deviceID: "a", timestamp: timestamp(),
                        epochMillis: pick([Int64.min, -1, 0, 1_000, 60_000, Int64.max]), activity: number() / 1_000,
                        sampleCount: pick([Int.min, -1, 0, 1, 50, Int.max]), source: pick(sources), quality: pick(flags))
        }
        let days = [LocalDay(year: 2026, month: 1, day: 6), LocalDay(year: 2026, month: 2, day: 31),
                    LocalDay(year: Int.max, month: 1, day: 1), LocalDay(year: 2026, month: 0, day: 0)]
        var daily: [LocalDay: Double?] = [:]
        for k in 0..<60 { daily[LocalDay(year: 2026, month: 1, day: 6).adding(days: -k, calendar: Fixture.utc)] = pick([nil, number()]) }
        let hrMax = pick([nil, MaxHeartRate(bpm: .nan, basis: .userOverride), MaxHeartRate(bpm: -5, basis: .userOverride),
                          MaxHeartRate(bpm: 1e300, basis: .userOverride), MaxHeartRate(bpm: 190, basis: .estimatedFromAge)])
        let resting = pick([nil, Double.nan, -3, 60, 500])

        let series = HeartRateSeries(hr)
        #expect(zip(series.samples, series.samples.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        _ = series.segments(maxGapMillis: pick([Int64.min, 0, 10_000, Int64.max]))
        for _ in 0..<4 {
            let r = range()
            _ = series.coverage(in: r)
            _ = series.coverageSpans(in: r)
            expectInvariants(series.summary(in: r))
            let zones = HeartRateZones(model: pick(HeartRateZoneModel.allCases), boundaries: pick([HeartRateZones.defaultBoundaries, [0.9, 0.1], []]),
                                       maxHeartRate: hrMax, restingHeartRate: resting)
            let w = WorkoutAnalyzer.summarize(range: r, series: series, zones: zones)
            expectInvariants(w.meanHeartRate)
            expectInvariants(w.maxHeartRate)
            expectInvariants(w.timeInZones)
            expectInvariants(w.edwardsTRIMP)
            expectInvariants(w.zoneThresholds)
            expectInvariants(TrainingLoad.banisterTRIMP(range: r, samples: hr, hrMax: hrMax, restingHeartRate: resting,
                                                        sex: pick([.female, .male, .unspecified])))
            expectInvariants(RestingHeartRateEstimator.estimate(sleepWindow: r, series: series).restingHeartRate)
            let hrv = HRVAnalyzer.analyze(beats: beats, range: r)
            expectInvariants(hrv.rmssd)
            expectInvariants(hrv.lnRMSSD)
            expectInvariants(hrv.rawRMSSD)
            let s = SleepSummary.fromConfirmedWindow(r, motion: motion, heartRate: hr)
            expectInvariants(s.timeInBed)
            expectInvariants(s.wakeDuration)
            expectInvariants(s.continuity)
            expectInvariants(s.meanHeartRate)
        }
        for day in days {
            expectInvariants(TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, series: series, hrMax: hrMax))
            expectInvariants(SleepDetector.detect(nightEndingOn: day, calendar: Fixture.utc, motion: motion, heartRate: hr))
            for period in TrendPeriod.allCases {
                expectInvariants(TrendAnalyzer.summary(of: daily, period: period, endingOn: day, calendar: Fixture.utc).statistics)
            }
            expectInvariants(TrendAnalyzer.recentVersusPrior(of: daily, endingOn: day, calendar: Fixture.utc))
            expectInvariants(BaselineCalculator.baseline(values: daily, targetDay: day, calendar: Fixture.utc))
            let readiness = ReadinessCalculator.compute(day: day, calendar: Fixture.utc, lnRMSSD: daily, restingHeartRate: daily,
                                                        sleepDurationMinutes: daily)
            expectInvariants(readiness.composite)
            #expect((readiness.band == nil) == (readiness.composite.value == nil))
        }
        let profile = UserProfile(birthYear: pick([nil, Int.min, 1990, Int.max]), sex: .unspecified,
                                  maxHeartRateOverride: pick([nil, Int.min, 0, 185, Int.max]),
                                  restingHeartRateOverride: pick([nil, Int.min, 55, Int.max]))
        expectInvariants(MaxHeartRateResolver.resolve(profile: profile, asOf: timestamp(), calendar: Fixture.utc))
        expectInvariants(HeartRateZones.resolve(profile: profile, asOf: timestamp(), calendar: Fixture.utc,
                                                model: .heartRateReserve).thresholds())
    }
}
