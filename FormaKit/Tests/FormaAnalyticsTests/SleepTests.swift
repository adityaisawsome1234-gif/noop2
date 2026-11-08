import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("Sleep candidates and confirmed-window summaries")
struct SleepTests {
    let h = Fixture.hour
    let m = Fixture.minute
    let morning = LocalDay(year: 2026, month: 1, day: 6)
    /// Noon 5 Jan → noon 6 Jan (UTC).
    var windowStart: EpochMillis { Fixture.t0 + 12 * h }
    var windowEnd: EpochMillis { Fixture.t0 + 36 * h }
    /// 23:00 → 07:00.
    var sleepStart: EpochMillis { Fixture.t0 + 23 * h }
    var sleepEnd: EpochMillis { Fixture.t0 + 31 * h }

    func isAsleep(_ t: EpochMillis) -> Bool { t >= sleepStart && t < sleepEnd }

    func motion(_ activity: (EpochMillis) -> Double?) -> [MotionEpoch] {
        Fixture.motionMinutes(from: windowStart, to: windowEnd, activity: activity)
    }

    var clearNight: [MotionEpoch] { motion { isAsleep($0) ? 0.003 : 0.08 } }

    /// Heart rate every 5 s over the whole window (full coverage).
    func heartRate(asleep: Int, awake: Int) -> [HeartRateSample] {
        Fixture.hrRun(from: windowStart, count: Int((windowEnd - windowStart) / 5_000), step: 5_000) { i in
            isAsleep(windowStart + Int64(i) * 5_000) ? asleep : awake
        }
    }

    @Test func clearNightWithoutHeartRate() throws {
        let result = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: clearNight)
        expectInvariants(result)
        let c = try #require(result.value)
        #expect(c.range == TimeRange(start: sleepStart, end: sleepEnd))
        #expect(c.wakeBouts.isEmpty)
        #expect(c.sleepDurationEstimateMillis == 8 * h)
        #expect(c.wakeAfterSleepOnsetMillis == 0)
        #expect(c.continuity == 1)
        #expect(c.coverage == 1)
        #expect(c.activityThreshold == 0.01)           // clamp(2 × P10 = 0.006, 0.01, 0.04)
        #expect(c.confidence == 0.7)                   // 0.5 × 1 + 0.2 × 1, no HR term
        #expect(result.confidence == .moderate)
        #expect(c.heartRateSupport == .unavailable(reason: "No heart-rate data"))
        #expect(result.window == TimeRange(start: windowStart, end: windowEnd))
        #expect(result.coverage == 1)                  // motion over the whole noon-to-noon window
        #expect(result.specID == MetricID.sleepCandidate)
        #expect(MetricCatalog.sleepCandidate.status == .estimate)
    }

    @Test func heartRateSupportRaisesConfidenceAndContradictionLowersIt() throws {
        let supported = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: clearNight,
                                                          heartRate: heartRate(asleep: 55, awake: 75)).value)
        #expect(supported.heartRateSupport == .supports(insideMeanBPM: 55, outsideMedianBPM: 75))
        #expect(supported.confidence == 1.0)

        let contradicted = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: clearNight,
                                                heartRate: heartRate(asleep: 80, awake: 70))
        #expect(contradicted.value?.heartRateSupport == .contradicts(insideMeanBPM: 80, outsideMedianBPM: 70))
        #expect(contradicted.value?.confidence == 0.4)
        #expect(contradicted.confidence == .low)

        // HR covering under half of the candidate is ignored (neutral).
        let sparse = Fixture.hrConstant(from: sleepStart, to: sleepStart + 3 * h, bpm: 50)
        let neutral = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: clearNight,
                                                        heartRate: sparse).value)
        #expect(neutral.confidence == 0.7)
        if case .unavailable(let reason) = neutral.heartRateSupport {
            #expect(reason.contains("50%"))
        } else {
            Issue.record("expected unavailable heart-rate support")
        }
    }

    @Test func fragmentedNightMergesShortWakeBouts() throws {
        // 8-min active bouts at 00:00, 01:00, …, 06:00: gaps ≤ 10 min are merged into one candidate.
        let midnight = Fixture.t0 + 24 * h
        let fragmented = motion { t in
            guard isAsleep(t) else { return 0.08 }
            return t >= midnight && (t - midnight) % h < 8 * m ? 0.1 : 0.003
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: fragmented).value)
        #expect(c.range == TimeRange(start: sleepStart, end: sleepEnd))
        #expect(c.wakeBouts.count == 7)
        #expect(c.wakeBouts.first == TimeRange(start: midnight, end: midnight + 8 * m))
        #expect(c.wakeAfterSleepOnsetMillis == 56 * m)
        #expect(c.sleepDurationEstimateMillis == 424 * m)
        #expect(abs(c.continuity - (1 - 56.0 / 480.0)) < 1e-12)
        #expect(c.confidence == 0.68)
    }

    @Test func tooFragmentedNightHasNoCandidate() {
        // 15-min active bouts every hour: quiet runs are never ≥ 3 h, even after merging (gaps > 10 min).
        let midnight = Fixture.t0 + 24 * h
        let broken = motion { t in
            guard isAsleep(t) else { return 0.08 }
            return t >= midnight && (t - midnight) % h < 15 * m ? 0.1 : 0.003
        }
        let r = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: broken)
        expectInvariants(r)
        #expect(r.value == nil)
        #expect(r.availability == .insufficientData(detail: "No quiet period of at least 3 h in this window; longest was 1 h"))
    }

    @Test func shortSpikesAreSmoothedAndLongerBoutsAreWake() throws {
        let spikeAt = Fixture.t0 + 26 * h, boutAt = Fixture.t0 + 28 * h
        let night = motion { t in
            guard isAsleep(t) else { return 0.08 }
            if t >= spikeAt && t < spikeAt + 2 * m { return 0.2 }   // 2 epochs: removed by the 5-epoch median
            if t >= boutAt && t < boutAt + 3 * m { return 0.2 }     // 3 epochs: a wake bout
            return 0.003
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: night).value)
        #expect(c.wakeBouts == [TimeRange(start: boutAt, end: boutAt + 3 * m)])
    }

    @Test func activityExactlyAtTheThresholdIsNotQuiet() throws {
        // θ = clamp(2 × 0.003, 0.01, 0.04) = 0.01; an 8-min stretch at exactly 0.01 is not "below θ", so it is
        // a wake bout inside the merged candidate (8 min ≤ the 10-min merge gap).
        let at = Fixture.t0 + 26 * h
        let night = motion { t in
            guard isAsleep(t) else { return 0.08 }
            return t >= at && t < at + 8 * m ? 0.01 : 0.003
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: night).value)
        #expect(c.activityThreshold == 0.01)
        #expect(c.range == TimeRange(start: sleepStart, end: sleepEnd))
        #expect(c.wakeBouts == [TimeRange(start: at, end: at + 8 * m)])
    }

    @Test func activeStretchOfExactlyTheMergeGapIsMerged() throws {
        let at = Fixture.t0 + 26 * h
        let night = motion { t in
            guard isAsleep(t) else { return 0.08 }
            return t >= at && t < at + 10 * m ? 0.05 : 0.003
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: night).value)
        #expect(c.range == TimeRange(start: sleepStart, end: sleepEnd))
        #expect(c.wakeBouts == [TimeRange(start: at, end: at + 10 * m)])
    }

    @Test func activeStretchLongerThanTheMergeGapSplitsTheNight() throws {
        // 30 min of activity at 02:00 splits 23:00–07:00 into 3 h and 4 h 30 min runs; the longer one wins.
        let at = Fixture.t0 + 26 * h
        let night = motion { t in
            guard isAsleep(t) else { return 0.08 }
            return t >= at && t < at + 30 * m ? 0.05 : 0.003
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: night).value)
        #expect(c.range == TimeRange(start: at + 30 * m, end: sleepEnd))
        #expect(c.wakeBouts.isEmpty)
    }

    @Test func noMotionIsUnsupportedEvenWithHeartRate() {
        let r = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: nil,
                                     heartRate: heartRate(asleep: 50, awake: 80))
        expectInvariants(r)
        #expect(r.value == nil)
        #expect(r.availability == .unsupportedSensor(sensor: "motion (accelerometer)"))
        #expect(r.availability.explanation == "Not provided by this band: motion (accelerometer)")

        let empty = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: [],
                                         heartRate: heartRate(asleep: 50, awake: 80))
        expectInvariants(empty)
        #expect(empty.availability == .insufficientData(detail: "No motion (accelerometer) data in this window"))
    }

    @Test func lowMotionCoverageIsLowQuality() {
        // During the night only every other minute has motion data.
        let gappy = motion { t in
            guard isAsleep(t) else { return 0.08 }
            return (t - sleepStart) % (2 * m) == 0 ? 0.003 : nil
        }
        let r = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: gappy)
        expectInvariants(r)
        #expect(r.availability.isLowQuality)
        #expect(r.coverage == 1_200.0 / 1_440.0)   // window coverage: 960 day epochs + 240 of 480 night epochs
        #expect(r.availability.detailText.contains("70%"))
    }

    @Test func offWristFlaggedEpochsAreMissingNotSleep() {
        let offWrist = Fixture.motionMinutes(from: windowStart, to: windowEnd) { _ in 0 }.map { epoch -> MotionEpoch in
            var e = epoch
            if isAsleep(e.timestamp) { e.quality = .noSensorContact } else { e.activity = 0.08 }
            return e
        }
        let r = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: offWrist,
                                     heartRate: heartRate(asleep: 50, awake: 80))
        expectInvariants(r)
        #expect(r.value == nil)
        #expect(r.availability.isInsufficientData)
    }

    @Test func noonToNoonWindowFollowsDST() throws {
        let berlin = try #require(Fixture.calendar("Europe/Berlin"))
        let day = LocalDay(year: 2026, month: 3, day: 29)    // clocks go forward at 02:00
        let window = try #require(SleepDetector.window(nightEndingOn: day, calendar: berlin))
        #expect(window.durationMillis == 23 * h)
        // 23:00 CET (22:00Z) to 07:00 CEST (05:00Z) is 7 h of real time.
        let asleep = TimeRange(start: window.start + 11 * h, end: window.start + 18 * h)
        let motion = Fixture.motionMinutes(from: window.start, to: window.end) { asleep.contains($0) ? 0.003 : 0.08 }
        let c = try #require(SleepDetector.detect(nightEndingOn: day, calendar: berlin, motion: motion).value)
        #expect(c.range == asleep)
        #expect(c.sleepDurationEstimateMillis == 7 * h)
    }

    @Test func motionEpochsAreRebinnedOntoMinutes() throws {
        // 1-s epochs (10 samples each) instead of 60-s epochs give the same candidate.
        var fine: [MotionEpoch] = []
        for t in stride(from: windowStart, to: windowEnd, by: 1_000) {
            fine.append(Fixture.motion(t, isAsleep(t) ? 0.003 : 0.08, samples: 10, epoch: 1_000))
        }
        let c = try #require(SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: fine).value)
        #expect(c.range == TimeRange(start: sleepStart, end: sleepEnd))
    }

    @Test func malformedMotionNeverCrashes() {
        let junk = [
            Fixture.motion(.max, 0.003), Fixture.motion(.min, 0.003),
            Fixture.motion(sleepStart, .nan), Fixture.motion(sleepStart, -1), Fixture.motion(sleepStart, .infinity),
            Fixture.motion(sleepStart, 0.003, samples: -5), Fixture.motion(sleepStart, 0.003, epoch: .min),
            Fixture.motion(sleepStart, 0.003, epoch: .max),
        ]
        let r = SleepDetector.detect(nightEndingOn: morning, calendar: Fixture.utc, motion: junk)
        expectInvariants(r)
        #expect(r.value == nil)
        let invalidDay = SleepDetector.detect(nightEndingOn: LocalDay(year: 2026, month: 2, day: 30), calendar: Fixture.utc,
                                              motion: clearNight)
        #expect(invalidDay.value == nil)
    }

    // MARK: Confirmed windows

    @Test func confirmedWindowWithMotionAndHeartRate() throws {
        let boutAt = Fixture.t0 + 27 * h
        let motion = Fixture.motionMinutes(from: sleepStart, to: sleepEnd) { t in
            t >= boutAt && t < boutAt + 10 * m ? 0.1 : 0.003
        }
        let window = TimeRange(start: sleepStart, end: sleepEnd)
        let hr = Fixture.hrConstant(from: sleepStart, to: sleepEnd, bpm: 55, step: 5_000)
        let s = SleepSummary.fromConfirmedWindow(window, motion: motion, heartRate: hr)
        #expect(s.timeInBed.value == 8 * h)
        #expect(s.timeInBed.confidence == .high)
        #expect(s.wakeBouts == [TimeRange(start: boutAt, end: boutAt + 10 * m)])
        #expect(s.wakeDuration.value == 10 * m)
        #expect(s.sleepDurationEstimate.value == 470 * m)
        let continuity = try #require(s.continuity.value)
        #expect(abs(continuity - (1 - 10.0 / 480.0)) < 1e-12)
        #expect(s.continuity.confidence == .moderate)     // motion-only wake detection is capped
        #expect(s.meanHeartRate.value == 55)
        #expect(s.motionCoverage == 1)
        #expect(s.heartRateCoverage == 1)
        for v in [s.timeInBed, s.wakeDuration, s.sleepDurationEstimate] { expectInvariants(v) }
        expectInvariants(s.continuity)
        expectInvariants(s.meanHeartRate)
        #expect(s.timeInBed.specID == MetricID.sleepSummary)
    }

    @Test func confirmedWindowWithoutMotionReportsOnlyTimeInBed() {
        let window = TimeRange(start: sleepStart, end: sleepEnd)
        let s = SleepSummary.fromConfirmedWindow(window, motion: nil)
        #expect(s.timeInBed.value == 8 * h)
        #expect(s.wakeBouts == nil)
        #expect(s.wakeDuration.availability == .unsupportedSensor(sensor: "motion (accelerometer)"))
        #expect(s.sleepDurationEstimate.value == nil)
        #expect(s.continuity.value == nil)
        #expect(s.meanHeartRate.availability == .insufficientData(detail: "No heart-rate data"))
        expectInvariants(s.wakeDuration)

        let empty = SleepSummary.fromConfirmedWindow(window, motion: [])
        #expect(empty.wakeDuration.availability.isInsufficientData)
        #expect(empty.motionCoverage == 0)

        let gappy = Fixture.motionMinutes(from: sleepStart, to: sleepEnd) { t in (t - sleepStart) % (2 * m) == 0 ? 0.003 : nil }
        let low = SleepSummary.fromConfirmedWindow(window, motion: gappy)
        #expect(low.timeInBed.value == 8 * h)
        #expect(low.continuity.availability.isLowQuality)
    }

    @Test func malformedConfirmedWindows() {
        for window in [TimeRange(start: sleepStart, end: sleepStart), TimeRange(start: sleepStart, end: sleepStart + 25 * h),
                       TimeRange(start: .min, end: .max)] {
            let s = SleepSummary.fromConfirmedWindow(window, motion: clearNight, heartRate: [])
            #expect(s.timeInBed.value == nil)
            expectInvariants(s.timeInBed)
            expectInvariants(s.continuity)
        }
    }
}
