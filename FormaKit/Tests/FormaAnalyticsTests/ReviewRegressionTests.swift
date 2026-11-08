import Foundation
import Testing
import FormaCore
import FormaAnalytics

// Regression tests for the correctness, spec and integration review findings. Each suite names the
// behaviour it pins; expectations are hand-computed from the documented method.

fileprivate enum RF {
    static let t0 = Fixture.t0
    static let s = Fixture.second
    static let m = Fixture.minute
    static let h = Fixture.hour

    static func flagged(_ samples: [HeartRateSample], _ flag: QualityFlags) -> [HeartRateSample] {
        samples.map { var x = $0; x.quality.insert(flag); return x }
    }

    static func flagged(_ beats: [BeatInterval], _ flag: QualityFlags) -> [BeatInterval] {
        beats.map { var x = $0; x.quality.insert(flag); return x }
    }

    /// A copy of `beats` from another source, `shift` ms later (new record keys, as a second stream would have).
    static func copy(_ beats: [BeatInterval], source: MeasurementSource, shift: Int64) -> [BeatInterval] {
        beats.map { b in
            BeatInterval(deviceID: b.deviceID, timestamp: b.timestamp + shift, intervalMillis: b.intervalMillis, source: source,
                         recordKey: b.recordKey + shift, indexInRecord: b.indexInRecord, receivedAt: b.receivedAt + shift,
                         timingBasis: .reconstructedFromReceiveTime, quality: b.quality)
        }
    }

    /// Window k (5 min, aligned to `start`) holds 289 beats, the first 4 s after the window start, with intervals
    /// cycling through `cycle`; a silence of several seconds separates windows, so each window is its own segment.
    static func cycleWindows(start: EpochMillis, windows: Int, cycle: [Double]) -> [BeatInterval] {
        var out: [BeatInterval] = []
        var index = 0
        for k in 0..<windows {
            var t = start + Int64(k) * 300_000 + 4_000
            for j in 0..<289 {
                let x = cycle[j % cycle.count]
                if j > 0 { t += Int64(x.rounded()) }
                out.append(Fixture.beat(t, x, index: index))
                index += 1
            }
        }
        return out
    }

    static func range(windows: Int, from start: EpochMillis = t0) -> TimeRange {
        TimeRange(start: start, end: start + Int64(windows) * 300_000)
    }
}

// MARK: - Unvalidated fields

@Suite("Review fixes: unvalidated fields never enter a metric")
struct UnvalidatedFieldTests {
    let t0 = RF.t0, h = RF.h, m = RF.m

    @Test func excludedFromTheSeriesAndItsCoverage() {
        #expect(HeartRateSeries.excludedFlags.contains(.unvalidatedField))
        #expect(HeartRateSeries.usable([Fixture.hr(t0, 60, quality: .unvalidatedField)]).isEmpty)
        #expect(!HeartRateSeries.isUsable(Fixture.hr(t0, 60, quality: [.unvalidatedField, .phoneReceiveTime])))
        let window = TimeRange(start: t0, end: t0 + 10 * m)
        let junk = RF.flagged(Fixture.hrConstant(from: t0, to: window.end, bpm: 150), .unvalidatedField)
        let series = HeartRateSeries(junk)
        #expect(series.isEmpty)
        #expect(series.coverage(in: window) == 0)
        #expect(series.coveredMillis(in: window) == 0)
        #expect(series.coverageSpans(in: window).isEmpty)
        #expect(series.segments().isEmpty)
        expectInvariants(series.summary(in: window))
        #expect(series.summary(in: window).value == nil)

        // Unvalidated samples after and between usable ones add no coverage, samples or spans.
        let good = Fixture.hrConstant(from: t0, to: t0 + 5 * m, bpm: 60, step: 2_000)
        let mixed = good + RF.flagged(Fixture.hrConstant(from: t0 + 5 * m, to: window.end, bpm: 150), .unvalidatedField)
            + RF.flagged(Fixture.hrRun(from: t0 + 1_000, count: 150, step: 2_000) { _ in 170 }, .unvalidatedField)
        #expect(HeartRateSeries(mixed) == HeartRateSeries(good))
        #expect(HeartRateSeries(mixed).coverage(in: window) == HeartRateSeries(good).coverage(in: window))
        #expect(HeartRateSeries(mixed).summary(in: window) == HeartRateSeries(good).summary(in: window))

        // An unvalidated history sample never suppresses a usable live one.
        let canonical = HeartRateSeries.canonical([Fixture.hr(t0, 70, quality: .unvalidatedField),
                                                   Fixture.hr(t0 + 1_000, 72, source: .liveVendorStream)])
        #expect(canonical.map(\.bpm) == [72])
    }

    /// Each metric computed from usable data plus unvalidated data equals the metric from the usable data alone,
    /// although the unvalidated values would change every result if they were used.
    @Test func excludedFromEveryHeartRateMetric() {
        let hrMax = MaxHeartRate(bpm: 190, basis: .userOverride)
        let zones = HeartRateZones(maxHeartRate: hrMax)

        // Workout: 30 usable minutes at 140 bpm in a 60-min workout; unvalidated 185 bpm fills the rest and
        // interleaves with the usable minutes.
        let start = t0 + 10 * h
        let workout = TimeRange(start: start, end: start + h)
        let good = Fixture.hrConstant(from: start, to: start + 30 * m, bpm: 140)
        let junk = RF.flagged(Fixture.hrConstant(from: start + 30 * m, to: start + h, bpm: 185), .unvalidatedField)
            + RF.flagged(Fixture.hrRun(from: start + 500, count: 1_800) { _ in 185 }, .unvalidatedField)
        let summary = WorkoutAnalyzer.summarize(range: workout, samples: good + junk, zones: zones)
        #expect(summary == WorkoutAnalyzer.summarize(range: workout, samples: good, zones: zones))
        #expect(summary.meanHeartRate.value == 140)
        #expect(summary.maxHeartRate.value == 140)
        #expect(summary.timeInZones.value?.millis(inZone: 5) == 0)
        #expect(TrainingLoad.workoutLoad(range: workout, samples: good + junk, hrMax: hrMax)
                == TrainingLoad.workoutLoad(range: workout, samples: good, hrMax: hrMax))
        #expect(TrainingLoad.banisterTRIMP(range: workout, samples: good + junk, hrMax: hrMax, restingHeartRate: 55, sex: .female)
                == TrainingLoad.banisterTRIMP(range: workout, samples: good, hrMax: hrMax, restingHeartRate: 55, sex: .female))

        // Daily load: 8 usable hours (33 %) plus 16 unvalidated hours that would lift coverage to 100 %.
        let day = LocalDay(year: 2026, month: 1, day: 5)
        let dayGood = Fixture.hrConstant(from: t0, to: t0 + 8 * h, bpm: 100)
        let dayJunk = RF.flagged(Fixture.hrConstant(from: t0 + 8 * h, to: t0 + 24 * h, bpm: 150), .unvalidatedField)
        let load = TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: dayGood + dayJunk, hrMax: hrMax)
        #expect(load == TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: dayGood, hrMax: hrMax))
        #expect(load.coverage.map { abs($0 - (8 * 3_600 + 4) / 86_400.0) < 1e-9 } == true)

        // Overnight resting HR: an unvalidated 30-min dip to 42 bpm would become the estimate if it were used.
        let night = TimeRange(start: t0 + 22 * h, end: t0 + 30 * h)
        let nightGood = Fixture.hrConstant(from: night.start, to: night.end, bpm: 58, step: 5_000)
        let dip = RF.flagged(Fixture.hrRun(from: night.start + 3 * h + 2_500, count: 360, step: 5_000) { _ in 42 }, .unvalidatedField)
        let rhr = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: nightGood + dip)
        #expect(rhr == RestingHeartRateEstimator.estimate(sleepWindow: night, samples: nightGood))
        #expect(rhr.restingHeartRate.value == 58)

        // Confirmed sleep window: mean heart rate ignores unvalidated samples.
        let sleepJunk = RF.flagged(Fixture.hrRun(from: night.start + 2_500, count: 5_760, step: 5_000) { _ in 95 }, .unvalidatedField)
        let sleep = SleepSummary.fromConfirmedWindow(night, motion: nil, heartRate: nightGood + sleepJunk)
        #expect(sleep == SleepSummary.fromConfirmedWindow(night, motion: nil, heartRate: nightGood))
        #expect(sleep.meanHeartRate.value == 58)
    }

    @Test func unvalidatedHeartRateNeverSupportsASleepCandidate() throws {
        let morning = LocalDay(year: 2026, month: 1, day: 6)
        let ws = t0 + 12 * h, we = t0 + 36 * h
        let asleep = TimeRange(start: t0 + 23 * h, end: t0 + 31 * h)
        let motion = Fixture.motionMinutes(from: ws, to: we) { asleep.contains($0) ? 0.003 : 0.08 }
        let supportive = Fixture.hrRun(from: ws, count: Int((we - ws) / 5_000), step: 5_000) { i in
            asleep.contains(ws + Int64(i) * 5_000) ? 50 : 80
        }
        let base = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: motion).value)
        let usable = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: motion,
                                                       heartRate: supportive).value)
        let unvalidated = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: motion,
                                                            heartRate: RF.flagged(supportive, .unvalidatedField)).value)
        #expect(usable.confidence > base.confidence)
        #expect(unvalidated.confidence == base.confidence)
        if case .unavailable = unvalidated.heartRateSupport {} else { Issue.record("unvalidated heart rate was used: \(unvalidated.heartRateSupport)") }
    }

    @Test func unvalidatedBeatsAreRejectedAsFlagged() {
        var beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        for i in stride(from: 7, to: beats.count, by: 50) { beats[i].quality = .unvalidatedField }
        let r = HRVAnalyzer.analyze(beats: beats, range: RF.range(windows: 6))
        #expect(HRVAnalyzer.flaggedQuality.contains(.unvalidatedField))
        #expect(r.artifacts.flagged == 36)
        #expect(r.acceptedBeats == 1_800 - 36)
        #expect(r.rmssd.value == 40)
        let all = HRVAnalyzer.analyze(beats: RF.flagged(beats, .unvalidatedField), range: RF.range(windows: 6))
        expectInvariants(all.rmssd)
        #expect(all.rmssd.value == nil)
        #expect(all.acceptedBeats == 0)
        #expect(all.artifacts.flagged == 1_800)
        #expect(all.rawRMSSD.value != nil, "the diagnostic value describes all beats, flagged ones included")
    }

    @Test func unvalidatedMotionIsMissingData() throws {
        #expect(SleepDetector.excludedMotionFlags.contains(.unvalidatedField))
        let morning = LocalDay(year: 2026, month: 1, day: 6)
        let ws = t0 + 12 * h, we = t0 + 36 * h
        let asleep = TimeRange(start: t0 + 23 * h, end: t0 + 31 * h)
        let clear = Fixture.motionMinutes(from: ws, to: we) { asleep.contains($0) ? 0.003 : 0.08 }
        // A night whose epochs are all unvalidated has no quiet period at all.
        let unvalidatedNight = clear.map { e -> MotionEpoch in
            var x = e
            if asleep.contains(x.timestamp) { x.quality = .unvalidatedField }
            return x
        }
        let none = SleepSummary.fromConfirmedWindow(asleep, motion: unvalidatedNight)
        #expect(none.sleepDurationEstimate.value == nil)
        #expect(none.motionCoverage == 0)
        let r = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: unvalidatedNight)
        expectInvariants(r)
        #expect(r.value == nil)
        // 6 unvalidated minutes inside the night (within the 10-min merge gap) are a wake bout, never sleep.
        let gap = TimeRange(start: asleep.start + 100 * m, end: asleep.start + 106 * m)
        let partly = clear.map { e -> MotionEpoch in
            var x = e
            if gap.contains(x.timestamp) { x.quality = .unvalidatedField }
            return x
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: partly).value)
        #expect(c.range == asleep)
        #expect(c.wakeBouts == [gap])
        #expect(c.sleepDurationEstimateMillis == 474 * m)
    }
}

// MARK: - HRV: duplicates, overlapping sources and overlapping timestamps

@Suite("Review fixes: HRV duplicates, overlapping sources and timestamps")
struct HRVSourceAndTimingTests {
    let t0 = RF.t0

    func expectSameAnalysis(_ a: HRVAnalysis, _ b: HRVAnalysis, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.rmssd.value == b.rmssd.value, sourceLocation: sourceLocation)
        #expect(a.rmssd.confidence == b.rmssd.confidence, sourceLocation: sourceLocation)
        #expect(a.rmssd.coverage == b.rmssd.coverage, sourceLocation: sourceLocation)
        #expect(a.lnRMSSD.value == b.lnRMSSD.value, sourceLocation: sourceLocation)
        #expect(a.rawRMSSD.value == b.rawRMSSD.value, sourceLocation: sourceLocation)
        #expect(a.windows == b.windows, sourceLocation: sourceLocation)
        #expect(a.totalBeats == b.totalBeats && a.acceptedBeats == b.acceptedBeats, sourceLocation: sourceLocation)
        #expect(a.artifacts == b.artifacts, sourceLocation: sourceLocation)
        #expect(a.segmentCount == b.segmentCount, sourceLocation: sourceLocation)
    }

    @Test func exactDuplicateRecordsCountOnce() {
        let beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        let once = HRVAnalyzer.analyze(beats: beats, range: RF.range(windows: 6))
        let twice = HRVAnalyzer.analyze(beats: beats + beats.reversed(), range: RF.range(windows: 6))
        expectSameAnalysis(twice, once)
        #expect(twice.rmssd.value == 40)                   // not 40 / √2
        #expect(twice.rmssd.confidence == .high)
        #expect(twice.rmssd.inputs["exactDuplicates"] == "1800 duplicate records counted once")
        #expect(once.rmssd.inputs["exactDuplicates"] == nil)
    }

    @Test(arguments: [37, 150, 3_000] as [Int64])
    func copiesFromLowerRankedSourcesGiveTheHistoryOnlyResult(shift: Int64) {
        let history = Fixture.alternatingWindows(start: t0, amplitudes: [10, 15, 20, 25, 30, 35, 40, 45])
        let range = RF.range(windows: 8)
        let alone = HRVAnalyzer.analyze(beats: history, range: range)
        #expect(alone.rmssd.value == 55)                   // median of 20…90
        let live = RF.copy(history, source: .liveVendorStream, shift: shift)
        let standard = RF.copy(history, source: .standardHeartRateService, shift: shift + 113)
        let merged = HRVAnalyzer.analyze(beats: standard + history + live, range: range)
        expectSameAnalysis(merged, alone)
        #expect(merged.validWindows == 8)
        #expect(merged.rmssd.inputs["sources"] == "band history")
        #expect(merged.rmssd.inputs["overlappingSources"] != nil)
        // Without history, the live stream wins over the standard service in the same way.
        let liveOnly = HRVAnalyzer.analyze(beats: live, range: range)
        let liveAndStandard = HRVAnalyzer.analyze(beats: live + standard, range: range)
        expectSameAnalysis(liveAndStandard, liveOnly)
    }

    @Test func aLowerRankedStreamFillsAGapInHistory() {
        let all = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 9))
        let gap = TimeRange(start: t0 + 3 * 300_000, end: t0 + 6 * 300_000)
        let history = all.filter { !gap.contains($0.timestamp) }
        let live = RF.copy(all, source: .liveVendorStream, shift: 37)
        let r = HRVAnalyzer.analyze(beats: history + live, range: RF.range(windows: 9))
        #expect(r.rmssd.value == 40)
        #expect(r.validWindows == 9)
        #expect(r.segmentCount == 3)                       // history | live | history
        #expect(r.rmssd.inputs["sources"] == "band history, live (vendor stream)")
        #expect(r.windows.allSatisfy { $0.rmssd == 40 })
    }

    @Test func unusableHistoryDoesNotHideAUsableLiveCopy() {
        // History decoded from a field not yet validated, plus a usable live copy of the same beats: the live copy
        // is used and the redundant history beats are dropped instead of interleaving with it.
        let history = RF.flagged(Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6)), .unvalidatedField)
        let live = RF.copy(Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6)),
                           source: .liveVendorStream, shift: 37)
        let r = HRVAnalyzer.analyze(beats: history + live, range: RF.range(windows: 6))
        #expect(r.rmssd.value == 40)
        #expect(r.validWindows == 6)
        #expect(r.artifacts.flagged == 0)
        #expect(r.rmssd.inputs["sources"] == "live (vendor stream)")
    }

    /// Spec-review probe: live notifications carry two beats each, reconstructed backwards from receive time, and
    /// every fifth notification arrives together with the next one, so their reconstructed timestamps overlap.
    @Test func overlappingReconstructedTimestampsAreNeverDifferenced() throws {
        let intervals: [Double] = (0..<1_800).map { $0 % 2 == 0 ? 980 : 1_020 }
        var trueTimes: [EpochMillis] = []
        var t = t0 - 500
        for x in intervals {
            t += Int64(x)
            trueTimes.append(t)
        }
        var beats: [BeatInterval] = []
        let notifications = intervals.count / 2
        for n in 0..<notifications {
            var received = trueTimes[2 * n + 1] + 40
            if n % 5 == 4, n + 1 < notifications { received = trueTimes[2 * n + 3] + 40 - 1 }   // delayed to the next one
            let second = intervals[2 * n + 1], first = intervals[2 * n]
            for (index, (stamp, x)) in [(received - Int64(second), first), (received, second)].enumerated() {
                beats.append(BeatInterval(deviceID: "band-1", timestamp: stamp, intervalMillis: x, source: .standardHeartRateService,
                                          recordKey: received, indexInRecord: index, receivedAt: received,
                                          timingBasis: .reconstructedFromReceiveTime))
            }
        }
        let r = HRVAnalyzer.analyze(beats: beats, range: RF.range(windows: 6))
        // Every pair that is formed joins two neighbouring heartbeats, so RMSSD stays 40 ms (never 0-difference pairs).
        #expect(r.rmssd.value == 40)
        #expect(r.windows.allSatisfy { $0.rmssd == nil || $0.rmssd == 40 })
        #expect(r.segmentCount > 1)
        #expect(r.validWindows == 6)
    }

    @Test func zeroSpacingStartsASegment() throws {
        let a = Fixture.beats(origin: t0, intervals: Array(repeating: 1_000, count: 5))
        let last = try #require(a.last)
        // Another record with a beat at the very same instant: never differenced with its twin.
        let twin = BeatInterval(deviceID: "band-1", timestamp: last.timestamp, intervalMillis: 1_010, source: .deviceHistory,
                                recordKey: last.recordKey + 1, indexInRecord: 0, receivedAt: last.timestamp,
                                timingBasis: .reconstructedFromRecordTime)
        let r = HRVAnalyzer.analyze(beats: a + [twin], range: RF.range(windows: 1))
        #expect(r.segmentCount == 2)
        #expect(r.rawRMSSD.value == 0)                     // only the 0-ms differences inside the first record remain
    }

    @Test func plausibleIntervalMuchLongerThanItsSpacingStartsASegment() {
        // 1000-ms beats, then a beat claiming 1000 ms only 400 ms after the previous one (overlap: break), then a
        // beat 499 ms later claiming 1000 ms (less than half: break) and one 500 ms later claiming 1000 ms (no break).
        let base = Fixture.beats(origin: t0, intervals: Array(repeating: 1_000, count: 4))
        let last = base.last?.timestamp ?? t0
        let r1 = HRVAnalyzer.analyze(beats: base + [Fixture.beat(last + 400, 1_000, index: 9)], range: RF.range(windows: 1))
        #expect(r1.segmentCount == 2)
        let r2 = HRVAnalyzer.analyze(beats: base + [Fixture.beat(last + 499, 1_000, index: 9)], range: RF.range(windows: 1))
        #expect(r2.segmentCount == 2)
        let r3 = HRVAnalyzer.analyze(beats: base + [Fixture.beat(last + 500, 1_000, index: 9)], range: RF.range(windows: 1))
        #expect(r3.segmentCount == 1)
        #expect(HRVAnalyzer.overlapFraction == 0.5)
    }

    @Test func withoutABeatSourceTheWindowsAreStillCounted() {
        let r = HRVAnalyzer.analyze(beats: nil, range: RF.range(windows: 6))
        #expect(r.totalWindows == 6)
        #expect(r.windows.count == 6)
        #expect(r.windows.allSatisfy { $0.invalidReason == "no beats" && $0.beats == 0 })
        #expect(r.rmssd.availability == .unsupportedSensor(sensor: "beat-to-beat intervals"))
        #expect(r.lnRMSSD.availability == .unsupportedSensor(sensor: "beat-to-beat intervals"))
        #expect(r.rawRMSSD.availability.isUnsupportedSensor)
        #expect(r.rmssd.coverage == nil)
        #expect(r.lnRMSSD.specID == MetricID.hrvLnRMSSD)
        for v in [r.rmssd, r.lnRMSSD, r.rawRMSSD] { expectInvariants(v) }
    }
}

// MARK: - Hand-computed values that a wrong formula cannot reproduce

@Suite("Review fixes: hand-computed RMSSD, median, MAD scale and θ")
struct HandComputedTests {
    let t0 = RF.t0

    @Test func irregularSeriesGivesTheRootMeanSquareNotTheMeanAbsoluteDifference() throws {
        // Intervals cycle 1000, 1010, 1030, 1000: differences +10, +20, −30, 0 over 72 whole cycles per window.
        // RMSSD = √((100 + 400 + 900 + 0) / 4) = √350 = 18.708 ms; mean |Δ| would be 15 ms.
        let beats = RF.cycleWindows(start: t0, windows: 6, cycle: [1_000, 1_010, 1_030, 1_000])
        let r = HRVAnalyzer.analyze(beats: beats, range: RF.range(windows: 6))
        #expect(r.validWindows == 6)
        #expect(r.windows.allSatisfy { $0.successivePairs == 288 && $0.rmssd == 18.7 })
        #expect(r.rmssd.value == 18.7)
        let ln = try #require(r.lnRMSSD.value)
        #expect(abs(ln - log(350.0.squareRoot())) < 0.0006)
    }

    @Test func periodValueIsTheMedianNotTheMean() {
        // Window RMSSDs 20, 20, 30, 40, 80, 90: median 35, mean 46.7.
        let beats = Fixture.alternatingWindows(start: t0, amplitudes: [10, 10, 15, 20, 40, 45])
        let r = HRVAnalyzer.analyze(beats: beats, range: RF.range(windows: 6))
        #expect(r.windows.map(\.rmssd) == [20, 20, 30, 40, 80, 90])
        #expect(r.rmssd.value == 35)
        #expect(r.lnRMSSD.value == 3.555)                  // ln 35 = 3.5553
    }

    @Test func madIsScaledBy1Point4826() throws {
        // Median 60 and MAD 1: the limit is 3 × 1.4826 × 1 = 4.448, so 64 (4 away) stays and 65 (5 away) goes.
        // Without the 1.4826 scale the limit would be 3 and 64 would be excluded too.
        let raw: [Double] = [59, 59, 59, 59, 60, 60, 60, 60, 60, 61, 61, 61, 61, 64]
        let kept = try #require(BaselineCalculator.robustStatistics(raw))
        #expect(kept.median == 60 && kept.medianAbsoluteDeviation == 1)
        #expect(kept.excluded == 0 && kept.n == 14)
        let withFar = try #require(BaselineCalculator.robustStatistics(raw + [65]))
        #expect(withFar.median == 60 && withFar.medianAbsoluteDeviation == 1)
        #expect(withFar.excluded == 1 && withFar.n == 14)
    }

    @Test func thresholdIsTwiceTheTenthPercentileInsideTheClamp() throws {
        // Night at 0.008 → P10 = 0.008 → θ = 0.016 (inside 0.01…0.04). An 8-min stretch at 0.018 is above θ and is
        // a wake bout; with θ = 3 × P10 = 0.024 it would be quiet.
        let h = RF.h, m = RF.m
        let ws = t0 + 12 * h, we = t0 + 36 * h
        let asleep = TimeRange(start: t0 + 23 * h, end: t0 + 31 * h)
        let stir = TimeRange(start: asleep.start + 200 * m, end: asleep.start + 208 * m)
        let motion = Fixture.motionMinutes(from: ws, to: we) { t in
            guard asleep.contains(t) else { return 0.08 }
            return stir.contains(t) ? 0.018 : 0.008
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: LocalDay(year: 2026, month: 1, day: 6), calendar: Fixture.utc,
                                                  motion: motion).value)
        #expect(abs(c.activityThreshold - 0.016) < 1e-12)
        #expect(c.range == asleep)
        #expect(c.wakeBouts == [stir])
        #expect(c.sleepDurationEstimateMillis == 472 * m)
    }
}

// MARK: - Sleep: unobserved time

@Suite("Review fixes: unobserved motion is never counted as sleep")
struct UnobservedSleepTests {
    let h = RF.h, m = RF.m
    let morning = LocalDay(year: 2026, month: 1, day: 6)
    var ws: EpochMillis { RF.t0 + 12 * h }
    var we: EpochMillis { RF.t0 + 36 * h }
    var asleep: TimeRange { TimeRange(start: RF.t0 + 23 * h, end: RF.t0 + 31 * h) }

    @Test func aWakeBoutWithEveryOtherMinuteMissingIsStillOneBout() throws {
        // Spec-review probe: 8 min of wake in which every second minute has no motion data. Active and missing
        // epochs form one non-quiet run, so the bout is found whole (the old active-only rule found none).
        let stir = TimeRange(start: asleep.start + 200 * m, end: asleep.start + 208 * m)
        let motion = Fixture.motionMinutes(from: ws, to: we) { t in
            guard asleep.contains(t) else { return 0.08 }
            guard stir.contains(t) else { return 0.003 }
            return ((t - stir.start) / RF.m) % 2 == 0 ? 0.1 : nil
        }
        let r = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: motion)
        let c = try #require(r.value)
        #expect(c.range == asleep)
        #expect(c.wakeBouts == [stir])
        #expect(c.wakeAfterSleepOnsetMillis == 8 * m)
        #expect(c.sleepDurationEstimateMillis == 472 * m)
        #expect(r.inputs["wakeBouts"] == "1 (8 min, of which 4 min without motion data)")
    }

    @Test func twoHoursWithoutMotionInAConfirmedWindowAreNotSleep() throws {
        // Correctness-review probe: 02:00–04:00 without motion in an 8-h window passes the 70 % coverage gate (75 %).
        let lost = TimeRange(start: asleep.start + 3 * h, end: asleep.start + 5 * h)
        let motion = Fixture.motionMinutes(from: asleep.start, to: asleep.end) { lost.contains($0) ? nil : 0.003 }
        let s = SleepSummary.fromConfirmedWindow(asleep, motion: motion)
        #expect(s.motionCoverage == 0.75)
        #expect(s.wakeBouts == [lost])
        #expect(s.wakeDuration.value == 2 * h)
        #expect(s.sleepDurationEstimate.value == 6 * h)
        #expect(s.continuity.value == 0.75)
        #expect(s.continuity.inputs["wakeBouts"] == "1 (2 h, of which 2 h without motion data)")
        #expect(s.timeInBed.value == 8 * h)
        // The same window flagged noSensorContact instead of absent gives the same result.
        let flagged = Fixture.motionMinutes(from: asleep.start, to: asleep.end) { _ in 0.003 }.map { e -> MotionEpoch in
            var x = e
            if lost.contains(x.timestamp) { x.quality = .noSensorContact }
            return x
        }
        #expect(SleepSummary.fromConfirmedWindow(asleep, motion: flagged).sleepDurationEstimate.value == 6 * h)
    }

    @Test func aSingleMissingEpochIsBridgedLikeASingleActiveOne() throws {
        let gapMinute = asleep.start + 150 * m
        let motion = Fixture.motionMinutes(from: ws, to: we) { t in
            guard asleep.contains(t) else { return 0.08 }
            return t == gapMinute ? nil : 0.003
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: motion).value)
        #expect(c.wakeBouts.isEmpty)
        #expect(c.sleepDurationEstimateMillis == 8 * h)
        #expect(abs(c.coverage - 479.0 / 480.0) < 1e-12)
    }

    @Test func heartRateSupportNeedsNoMinimumTimeOutsideByDefault() {
        #expect(SleepDetectorParameters.default.minimumOutsideHeartRateMillis == 0)
        // Raising the parameter restores a minimum comparison period, with its own reason.
        let p = SleepDetectorParameters(minimumOutsideHeartRateMillis: 30 * m)
        let motion = Fixture.motionMinutes(from: ws, to: we) { asleep.contains($0) ? 0.003 : 0.08 }
        let hr = Fixture.hrRun(from: asleep.start - 20 * m, count: 240, step: 5_000) { _ in 75 }
            + Fixture.hrRun(from: asleep.start, count: 8 * 720, step: 5_000) { _ in 52 }
        let strict = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: motion, heartRate: hr, parameters: p)
        #expect(strict.value?.heartRateSupport == .unavailable(reason: "Less than 30 min of heart rate outside the candidate to compare with"))
        let lenient = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: motion, heartRate: hr)
        #expect(lenient.value?.heartRateSupport == .supports(insideMeanBPM: 52, outsideMedianBPM: 75))
    }
}

// MARK: - Calendars

@Suite("Review fixes: calendars")
struct CalendarSystemTests {
    static let identifiers: [Calendar.Identifier] = [.japanese, .buddhist, .hebrew, .persian, .islamicUmmAlQura, .republicOfChina]

    func calendar(_ id: Calendar.Identifier, zone: String = "UTC") -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0) ?? c.timeZone
        return c
    }

    /// Whatever calendar system the phone uses, days are Gregorian dates and every day-based result equals the
    /// Gregorian one (correctness-review probe: these all returned "Invalid day" before).
    @Test(arguments: identifiers)
    func dayBasedResultsDoNotDependOnTheCalendarSystem(_ id: Calendar.Identifier) throws {
        let other = calendar(id)
        let gregorian = Fixture.utc
        let end = LocalDay(year: 2026, month: 3, day: 31)
        let values = dailyValues(endingOn: end, count: 40) { Double(50 + $0 % 7) }
        for period in TrendPeriod.allCases {
            let s = TrendAnalyzer.summary(of: values, period: period, endingOn: end, calendar: other)
            #expect(s == TrendAnalyzer.summary(of: values, period: period, endingOn: end, calendar: gregorian), "\(id) \(period)")
            #expect(s.statistics.value != nil || period == .days90)
        }
        #expect(TrendAnalyzer.recentVersusPrior(of: values, endingOn: end, calendar: other)
                == TrendAnalyzer.recentVersusPrior(of: values, endingOn: end, calendar: gregorian))
        #expect(BaselineCalculator.baseline(values: values, targetDay: end, calendar: other)
                == BaselineCalculator.baseline(values: values, targetDay: end, calendar: gregorian))
        #expect(ReadinessCalculator.compute(day: end, calendar: other, lnRMSSD: values, restingHeartRate: values, sleepDurationMinutes: [:])
                == ReadinessCalculator.compute(day: end, calendar: gregorian, lnRMSSD: values, restingHeartRate: values, sleepDurationMinutes: [:]))

        let day = LocalDay(year: 2026, month: 1, day: 5)
        let hr = Fixture.hrConstant(from: Fixture.t0, to: Fixture.t0 + 8 * RF.h, bpm: 110, step: 2_000)
        let hrMax = MaxHeartRate(bpm: 190, basis: .userOverride)
        let load = TrainingLoad.dailyLoad(day: day, calendar: other, samples: hr, hrMax: hrMax)
        #expect(load.value != nil)
        #expect(load == TrainingLoad.dailyLoad(day: day, calendar: gregorian, samples: hr, hrMax: hrMax))

        let morning = LocalDay(year: 2026, month: 1, day: 6)
        let window = try #require(SleepDetector.window(nightEndingOn: morning, calendar: other))
        #expect(window == SleepDetector.window(nightEndingOn: morning, calendar: gregorian))
        let motion = Fixture.motionMinutes(from: window.start, to: window.end) { t in
            t >= Fixture.t0 + 23 * RF.h && t < Fixture.t0 + 31 * RF.h ? 0.003 : 0.08
        }
        #expect(SleepDetector.detect(nightEndingOn: morning, calendar: other, motion: motion)
                == SleepDetector.detect(nightEndingOn: morning, calendar: gregorian, motion: motion))
    }

    @Test func onlyTheTimeZoneOfTheCalendarIsUsed() throws {
        let tokyoBuddhist = calendar(.buddhist, zone: "Asia/Tokyo")
        let tokyo = try #require(Fixture.calendar("Asia/Tokyo"))
        let day = LocalDay(year: 2026, month: 1, day: 5)
        let hr = Fixture.hrConstant(from: Fixture.t0 - 9 * RF.h, to: Fixture.t0 + 15 * RF.h, bpm: 110, step: 2_000)
        let hrMax = MaxHeartRate(bpm: 190, basis: .userOverride)
        let load = TrainingLoad.dailyLoad(day: day, calendar: tokyoBuddhist, samples: hr, hrMax: hrMax)
        #expect(load.window == TimeRange(start: Fixture.t0 - 9 * RF.h, end: Fixture.t0 + 15 * RF.h))
        #expect(load == TrainingLoad.dailyLoad(day: day, calendar: tokyo, samples: hr, hrMax: hrMax))
    }

    @Test func dayRangesEndAtTheNextDaysStartWhenDSTSkipsMidnight() throws {
        // America/Santiago 2026-09-06 starts at 01:00 (midnight is skipped) and must end at 2026-09-07 00:00.
        let santiago = try #require(Fixture.calendar("America/Santiago"))
        let sept7 = EpochMillis(date: try #require(santiago.date(from: DateComponents(year: 2026, month: 9, day: 7))))
        let window = try #require(TrainingLoad.dailyLoad(day: LocalDay(year: 2026, month: 9, day: 6), calendar: santiago,
                                                         samples: [], hrMax: MaxHeartRate(bpm: 190, basis: .userOverride)).window)
        #expect(window.end == sept7)
        #expect(window.durationMillis == 23 * RF.h)
        let next = try #require(TrainingLoad.dailyLoad(day: LocalDay(year: 2026, month: 9, day: 7), calendar: santiago,
                                                       samples: [], hrMax: MaxHeartRate(bpm: 190, basis: .userOverride)).window)
        #expect(next.start == window.end)
    }
}

// MARK: - Readiness

@Suite("Review fixes: readiness rounding and calibration text")
struct ReadinessReviewTests {
    let day = LocalDay(year: 2026, month: 2, day: 10)

    func history(_ value: Double, nights: Int, target: Double?) -> [LocalDay: Double?] {
        var out = dailyValues(endingOn: day.adding(days: -1, calendar: Fixture.utc), count: nights) { _ in value }
        if let target { out[day] = target }
        return out
    }

    @Test func compositeUsesUnroundedZScores() throws {
        // Correctness-review probe: HRV z = 1.0049, resting-HR z = 1.0149 (SD floors). Σwz/Σw = 1.00865 → 1.01, above
        // usual. Rounding each z first would give 1.00375 → 1.00, within usual.
        let r = ReadinessCalculator.compute(day: day, calendar: Fixture.utc,
                                            lnRMSSD: history(4.0, nights: 20, target: 4.0 + 1.004_9 * 0.05),
                                            restingHeartRate: history(50, nights: 20, target: 50 - 1.014_9),
                                            sleepDurationMinutes: [:])
        expectInvariants(r.composite)
        #expect(r.composite.value == 1.01)
        #expect(r.band == .aboveUsual)
        #expect(r.component(.hrv)?.z == 1.0)              // displayed values stay rounded
        #expect(r.component(.restingHeartRate)?.z == 1.01)
    }

    @Test func calibrationTextNamesNightsLeftOutAsOutliers() throws {
        // 14 eligible HRV nights, one of them an outlier: 13 retained of 14 needed, and the text says why.
        let values: [Double] = [4.0, 4.01, 3.99, 4.0, 4.02, 3.98, 4.0, 4.01, 3.99, 4.0, 4.01, 3.99, 4.0, 5.0]
        var hrv = dailyValues(endingOn: day.adding(days: -1, calendar: Fixture.utc), count: values.count) { values[$0] }
        hrv[day] = 4.05
        let r = ReadinessCalculator.compute(day: day, calendar: Fixture.utc, lnRMSSD: hrv, restingHeartRate: [:],
                                            sleepDurationMinutes: [:])
        #expect(r.composite.availability == .calibrating(have: 13, need: 14, unit: "nights"))
        let c = try #require(r.component(.hrv))
        #expect(c.calibrationHave == 13)
        #expect(c.baseline.inputs["excludedOutliers"] == "1")
        #expect(c.baseline.inputs["eligibleDays"] == "14 of 28")
        let text = try #require(r.composite.inputs["hrv"])
        #expect(text.contains("1 unusual night left out of the baseline as an outlier"), "\(text)")
    }

    @Test func confidenceTextMatchesTheRule() {
        let method = MetricCatalog.readiness.method
        #expect(method.contains("moderate with two or more components (three with fewer than 21 HRV baseline nights)"))
        #expect(method.contains("unrounded z values"))
    }
}

// MARK: - Trends, reasons, units, counts and totals

@Suite("Review fixes: trends, reasons, units, counts and totals")
struct MiscellaneousReviewTests {
    let end = LocalDay(year: 2026, month: 3, day: 31)

    func comparison(prior: Double, recent: Double, metricID: String? = nil) -> RecentVersusPrior? {
        let values = dailyValues(endingOn: end, count: 35) { $0 < 28 ? prior : recent }
        return TrendAnalyzer.recentVersusPrior(of: values, endingOn: end, calendar: Fixture.utc, metricID: metricID).value
    }

    @Test func percentageOnlyForRatioScaleMeans() {
        #expect(comparison(prior: 50, recent: 55)?.percentDifference == 10)
        #expect(comparison(prior: 50, recent: 0)?.percentDifference == -100)
        // Spec-review probe: a z-score-like series must not report +2400 %.
        #expect(comparison(prior: 0.02, recent: 0.5, metricID: MetricID.readiness)?.percentDifference == nil)
        #expect(comparison(prior: 3.8, recent: 4.0, metricID: MetricID.hrvLnRMSSD)?.percentDifference == nil)
        #expect(comparison(prior: -1, recent: 1)?.percentDifference == nil)
        #expect(comparison(prior: -2, recent: -1)?.percentDifference == nil)
        #expect(comparison(prior: 0.02, recent: 0.5, metricID: MetricID.readiness).map { abs($0.difference - 0.48) < 1e-12 } == true)
        #expect(TrendAnalyzer.nonRatioMetricIDs == [MetricID.readiness, MetricID.hrvLnRMSSD])
        #expect(MetricCatalog.trends.method.contains("ratio scale"))
    }

    @Test func aMissingSettingIsReportedBeforeLowCoverage() {
        // Correctness/spec-review probe: no HRmax and only 100 samples in the day.
        let sparse = Fixture.hrRun(from: Fixture.t0, count: 100) { _ in 120 }
        let day = LocalDay(year: 2026, month: 1, day: 5)
        let load = TrainingLoad.dailyLoad(day: day, calendar: Fixture.utc, samples: sparse, hrMax: nil)
        #expect(load.availability == .insufficientData(detail: "Set your max heart rate or birth year"))
        #expect(load.coverage != nil)
        let range = TimeRange(start: Fixture.t0, end: Fixture.t0 + RF.h)
        let hrMax = MaxHeartRate(bpm: 190, basis: .userOverride)
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: sparse, hrMax: nil, restingHeartRate: 50, sex: .male).availability
                == .insufficientData(detail: MaxHeartRateResolver.missingInputDetail))
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: sparse, hrMax: hrMax, restingHeartRate: nil, sex: .male).availability
                == .insufficientData(detail: TrainingLoad.missingRestingDetail))
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: sparse, hrMax: hrMax, restingHeartRate: 50, sex: .unspecified).availability
                == .insufficientData(detail: TrainingLoad.missingSexDetail))
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: sparse, hrMax: hrMax, restingHeartRate: 50, sex: .male).availability.isLowQuality)
        let workout = WorkoutAnalyzer.summarize(range: range, samples: sparse, zones: HeartRateZones(maxHeartRate: nil))
        #expect(workout.timeInZones.availability == .insufficientData(detail: "Set your max heart rate or birth year"))
        #expect(workout.meanHeartRate.availability.isLowQuality)
        // The series overload gives the same result as the samples overload.
        #expect(TrainingLoad.banisterTRIMP(range: range, series: HeartRateSeries(sparse), hrMax: hrMax, restingHeartRate: 50, sex: .male)
                == TrainingLoad.banisterTRIMP(range: range, samples: sparse, hrMax: hrMax, restingHeartRate: 50, sex: .male))
    }

    /// The unit of every value is the unit of the spec it is stamped with (the store and the methodology page take
    /// units from the catalog).
    @Test func everyValueCarriesASpecWithItsOwnUnit() throws {
        func unit<V>(_ m: MetricValue<V>) -> String? { MetricCatalog.spec(for: m.specID)?.unit }
        let hrv = HRVAnalyzer.analyze(beats: Fixture.alternatingWindows(start: Fixture.t0, amplitudes: Array(repeating: 20, count: 6)),
                                      range: RF.range(windows: 6))
        #expect(unit(hrv.rmssd) == "ms")
        #expect(unit(hrv.lnRMSSD) == "ln(ms)")
        #expect(hrv.lnRMSSD.specID == MetricID.hrvLnRMSSD)
        #expect(unit(hrv.rawRMSSD) == "ms")
        let empty = HRVAnalyzer.analyze(beats: [], range: RF.range(windows: 6))
        #expect(empty.lnRMSSD.specID == MetricID.hrvLnRMSSD)

        let night = TimeRange(start: Fixture.t0 + 23 * RF.h, end: Fixture.t0 + 31 * RF.h)
        let s = SleepSummary.fromConfirmedWindow(night, motion: Fixture.motionMinutes(from: night.start, to: night.end) { _ in 0.003 },
                                                 heartRate: Fixture.hrConstant(from: night.start, to: night.end, bpm: 55, step: 5_000))
        #expect(unit(s.timeInBed) == "ms" && unit(s.wakeDuration) == "ms" && unit(s.sleepDurationEstimate) == "ms")
        #expect(unit(s.continuity) == "fraction (0–1)")
        #expect(s.continuity.specID == MetricID.sleepContinuity)
        #expect(unit(s.meanHeartRate) == "bpm")
        #expect(s.meanHeartRate.specID == MetricID.sleepHeartRate)
        let none = SleepSummary.fromConfirmedWindow(night, motion: nil)
        #expect(none.continuity.specID == MetricID.sleepContinuity && none.meanHeartRate.specID == MetricID.sleepHeartRate)
        for v in [s.continuity, s.meanHeartRate, none.continuity, none.meanHeartRate] { expectInvariants(v) }

        #expect(MetricCatalog.diagnosticSpecIDs == [MetricID.hrvRawRMSSD])
        #expect(try #require(MetricCatalog.spec(for: MetricID.hrvRawRMSSD)).name.contains("diagnostic only"))
        #expect(!MetricCatalog.diagnosticSpecIDs.contains(hrv.rmssd.specID))
    }

    @Test func catalogStatesTheReviewedRules() throws {
        func text(_ spec: MetricSpec) -> String {
            ([spec.method, spec.windowing] + spec.qualityGates + spec.limitations + spec.requiredInputs).joined(separator: "\n")
        }
        let hrv = text(MetricCatalog.hrvRMSSD)
        for fragment in ["exact duplicates", "band history > live vendor stream > backup import > standard Heart Rate Service > demo",
                         "zero or negative", "less than half of the beat's own plausible interval", "A period median RMSSD of 0 ms",
                         "unvalidatedField", "ties: source rank, device ID, record key, index in record", "sustained heart-rate change"] {
            #expect(hrv.contains(fragment), "forma.hrv.rmssd: \(fragment)")
        }
        #expect(text(MetricCatalog.sleepCandidate).contains("non-quiet runs (active epochs or epochs without motion data)"))
        #expect(text(MetricCatalog.sleepCandidate).contains("unvalidatedField"))
        #expect(text(MetricCatalog.sleepSummary).contains("non-quiet runs (active epochs or epochs without motion data)"))
        #expect(text(MetricCatalog.heartRateZones).contains("capped at low when HRmax is estimated from age"))
        #expect(text(MetricCatalog.edwardsLoad).contains("capped at low when HRmax is estimated from age"))
        #expect(text(MetricCatalog.edwardsLoad).contains("to the start of the next day"))
        #expect(text(MetricCatalog.heartRateSeries).contains("unvalidatedField"))
        #expect(text(MetricCatalog.trends).contains("Gregorian"))
        #expect(MetricCatalog.hrvLnRMSSD.unit == "ln(ms)")
        // Every spec whose results changed in this revision carries a new version.
        for spec in [MetricCatalog.heartRateSeries, MetricCatalog.hrvRMSSD, MetricCatalog.sleepCandidate, MetricCatalog.sleepSummary,
                     MetricCatalog.readiness, MetricCatalog.edwardsLoad] {
            #expect(spec.version >= 2, "\(spec.id)")
        }
    }

    @Test func restingHeartRateCountsAreRealWhenTheGateFails() {
        // Spec-review probe: an 8-h window with no heart rate still has 476 windows, none eligible.
        let night = TimeRange(start: Fixture.t0, end: Fixture.t0 + 8 * RF.h)
        let r = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: [])
        #expect(r.restingHeartRate.availability.isInsufficientData)
        #expect(r.totalWindows == 476)
        #expect(r.eligibleWindows == 0)
        // Two good hours (covered until 2 h 4 s): the 3-h gate fails, but the scan still counts the eligible
        // windows: those starting at 0…116 min (the last one is covered 244 of 300 s, ≥ 80 %).
        let two = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: Fixture.hrConstant(from: night.start, to: night.start + 2 * RF.h, bpm: 55))
        #expect(two.restingHeartRate.value == nil)
        #expect(two.totalWindows == 476 && two.eligibleWindows == 117)
    }

    @Test func lowestWindowIsDescribedForPeople() throws {
        let night = TimeRange(start: Fixture.t0, end: Fixture.t0 + 6 * RF.h)
        let dip = night.start + 2 * RF.h + 15 * RF.m
        let samples = Fixture.hrRun(from: night.start, count: Int(6 * RF.h / 1_000)) { i in
            let t = night.start + Int64(i) * 1_000
            return t >= dip && t < dip + 5 * RF.m ? 48 : 60
        }
        let r = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples)
        #expect(r.restingHeartRate.value == 48)
        #expect(r.lowestWindow == TimeRange(start: dip, end: dip + 5 * RF.m))
        #expect(r.restingHeartRate.inputs["lowestWindow"] == "2 h 15 min to 2 h 20 min after the start of the sleep window")
    }

    @Test func totalsSaturateInsteadOfTrapping() throws {
        #expect(ZoneDurations(millis: [.max, 1]).totalMillis == .max)
        #expect(ZoneDurations(millis: [.min, -1]).totalMillis == .min)
        #expect(ZoneDurations(millis: [1_000, 2_000]).totalMillis == 3_000)
        let decoded = try JSONDecoder().decode(ZoneDurations.self, from: Data("{\"millis\":[9223372036854775807,9223372036854775807]}".utf8))
        #expect(decoded.totalMillis == .max)
        #expect(HRVArtifactCounts(ruleA: .max, ruleB: 1).total == .max)
        #expect(HRVArtifactCounts(ruleA: 2, ruleB: 3, flagged: 4).total == 9)
    }
}

// MARK: - Extreme parameters (child process, so a trap is reported instead of ending the run)

#if os(macOS) || os(Linux) || os(Windows)
@Suite("Review fixes: extreme parameter values never trap")
struct ExtremeParameterTests {
    /// Every field of every parameters struct at Int64/Int extremes, 0, −1, NaN and ±∞, one field at a time.
    @Test func everyParameterFieldAtItsExtremes() async {
        await #expect(processExitsWith: .success) {
            let t0: EpochMillis = 1_767_571_200_000
            let hour: Int64 = 3_600_000
            let night = TimeRange(start: t0, end: t0 + 8 * hour)
            let hr = (0..<5_760).map {
                HeartRateSample(deviceID: "b", timestamp: t0 + Int64($0) * 5_000, bpm: 50 + $0 % 40, source: .deviceHistory, receivedAt: t0)
            }
            let series = HeartRateSeries(hr)
            let int64s: [Int64] = [.min, -1, 0, 1, 999, 1_000, 60_000, .max - 1, .max]
            let ints: [Int] = [.min, -1, 0, 1, 2, 50, 51, 61, .max]
            let doubles: [Double] = [-.infinity, -1, 0, 0.5, 1, 2, .infinity, .nan, .greatestFiniteMagnitude]

            var rhr: [RestingHeartRateParameters] = []
            for v in int64s {
                for k in 0..<5 {
                    var p = RestingHeartRateParameters()
                    switch k {
                    case 0: p.windowMillis = v
                    case 1: p.stepMillis = v
                    case 2: p.minimumCoveredMillis = v
                    case 3: p.shortWindowThresholdMillis = v
                    default: p.maximumSleepWindowMillis = v
                    }
                    rhr.append(p)
                }
            }
            for v in doubles {
                rhr.append(RestingHeartRateParameters(minimumWindowCoverage: v))
                rhr.append(RestingHeartRateParameters(shortWindowMinimumCoverage: v))
            }
            for p in rhr { _ = RestingHeartRateEstimator.estimate(sleepWindow: night, series: series, parameters: p) }

            var beats: [BeatInterval] = []
            var t = t0
            for i in 0..<7_000 {
                let x = Double(980 + (i % 3) * 20)
                t += Int64(x)
                beats.append(BeatInterval(deviceID: "b", timestamp: t, intervalMillis: x, source: i % 97 == 0 ? .liveVendorStream : .deviceHistory,
                                          recordKey: t, indexInRecord: i, receivedAt: t, timingBasis: .reconstructedFromRecordTime))
            }
            let period = TimeRange(start: t0, end: t0 + 2 * hour)
            var hrv: [HRVParameters] = []
            for v in int64s {
                var a = HRVParameters(); a.windowMillis = v; hrv.append(a)
                var b = HRVParameters(); b.maximumAnalysisMillis = v; hrv.append(b)
            }
            for v in ints {
                var a = HRVParameters(); a.ruleBReferenceBeats = v; hrv.append(a)
                var b = HRVParameters(); b.ruleBMinimumReferences = v; hrv.append(b)
                var c = HRVParameters(); c.windowMinimumPairs = v; hrv.append(c)
                var d = HRVParameters(); d.minimumValidWindows = v; hrv.append(d)
            }
            for v in doubles {
                for k in 0..<8 {
                    var p = HRVParameters()
                    switch k {
                    case 0: p.dropoutToleranceMillis = v
                    case 1: p.ruleBMaximumDeviation = v
                    case 2: p.windowMinimumAcceptedFraction = v
                    case 3: p.windowMinimumAcceptedMillis = v
                    case 4: p.highConfidenceMinimumCoverage = v
                    case 5: p.highConfidenceMaximumArtifactRate = v
                    case 6: p.moderateConfidenceMinimumCoverage = v
                    default: p.moderateConfidenceMaximumArtifactRate = v
                    }
                    hrv.append(p)
                }
            }
            for p in hrv { _ = HRVAnalyzer.analyze(beats: beats, range: period, parameters: p) }

            let ws = t0 + 12 * hour
            let motion = stride(from: ws, to: ws + 24 * hour, by: 60_000).map {
                MotionEpoch(deviceID: "b", timestamp: $0, epochMillis: 60_000, activity: ($0 / 60_000) % 7 == 0 ? 0.08 : 0.003,
                            sampleCount: ($0 / 60_000) % 11 == 0 ? 0 : 10, source: .deviceHistory)
            }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
            var sleep: [SleepDetectorParameters] = []
            for v in int64s {
                for k in 0..<5 {
                    var p = SleepDetectorParameters()
                    switch k {
                    case 0: p.epochMillis = v
                    case 1: p.mergeGapMillis = v
                    case 2: p.minimumCandidateMillis = v
                    case 3: p.minimumOutsideHeartRateMillis = v
                    default: p.maximumConfirmedWindowMillis = v
                    }
                    sleep.append(p)
                }
            }
            for v in ints {
                var a = SleepDetectorParameters(); a.rollingMedianEpochs = v; sleep.append(a)
                var b = SleepDetectorParameters(); b.minimumWakeBoutEpochs = v; sleep.append(b)
                var c = SleepDetectorParameters(); c.windowStartHour = v; sleep.append(c)
            }
            for v in doubles {
                for k in 0..<10 {
                    var p = SleepDetectorParameters()
                    switch k {
                    case 0: p.thresholdPercentile = v
                    case 1: p.thresholdMultiplier = v
                    case 2: p.thresholdLowerBound = v
                    case 3: p.thresholdUpperBound = v
                    case 4: p.minimumMotionCoverage = v
                    case 5: p.minimumHeartRateCoverage = v
                    case 6: p.confidenceMotionWeight = v
                    case 7: p.confidenceContinuityWeight = v
                    case 8: p.confidenceHeartRateSupport = v
                    default: p.confidenceHeartRateContradiction = v
                    }
                    sleep.append(p)
                }
            }
            let confirmed = TimeRange(start: t0 + 23 * hour, end: t0 + 31 * hour)
            for p in sleep {
                _ = SleepDetector.window(nightEndingOn: LocalDay(year: 2026, month: 1, day: 6), calendar: cal, parameters: p)
                _ = SleepDetector.detect(nightEndingOn: LocalDay(year: 2026, month: 1, day: 6), calendar: cal, motion: motion,
                                         heartRate: hr, parameters: p)
                _ = SleepSummary.fromConfirmedWindow(confirmed, motion: motion, heartRate: hr, parameters: p)
            }

            let day = LocalDay(year: 2026, month: 3, day: 31)
            var values: [LocalDay: Double?] = [:]
            for k in 0..<40 { values[day.adding(days: -k, calendar: cal)] = 4 + Double(k % 5) / 100 }
            var baselines: [BaselineParameters] = []
            for v in ints {
                baselines.append(BaselineParameters(windowDays: v))
                baselines.append(BaselineParameters(minimumDays: v))
            }
            for v in doubles {
                baselines.append(BaselineParameters(outlierMADMultiplier: v))
                baselines.append(BaselineParameters(madScale: v))
            }
            for p in baselines { _ = BaselineCalculator.baseline(values: values, targetDay: day, calendar: cal, parameters: p) }

            var readiness: [ReadinessParameters] = []
            for v in ints {
                for k in 0..<5 {
                    var p = ReadinessParameters()
                    switch k {
                    case 0: p.baselineDays = v
                    case 1: p.hrvMinimumNights = v
                    case 2: p.restingHeartRateMinimumNights = v
                    case 3: p.sleepMinimumNights = v
                    default: p.highConfidenceMinimumHRVNights = v
                    }
                    readiness.append(p)
                }
            }
            for v in doubles {
                for k in 0..<7 {
                    var p = ReadinessParameters()
                    switch k {
                    case 0: p.lnRMSSDStandardDeviationFloor = v
                    case 1: p.restingHeartRateStandardDeviationFloor = v
                    case 2: p.sleepStandardDeviationFloorMinutes = v
                    case 3: p.weights.hrv = v
                    case 4: p.weights.restingHeartRate = v
                    case 5: p.weights.sleepDuration = v
                    default: p.bandThreshold = v
                    }
                    readiness.append(p)
                }
            }
            for p in readiness {
                let r = ReadinessCalculator.compute(day: day, calendar: cal, lnRMSSD: values, restingHeartRate: values,
                                                    sleepDurationMinutes: values, parameters: p)
                if let c = r.composite.coverage, !(c.isFinite && c >= 0 && c <= 1) { fatalError("coverage \(c)") }
            }
        }
    }
}
#endif
