import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("Heart-rate series")
struct HeartRateSeriesTests {
    let t0 = Fixture.t0

    @Test func usableExcludesFlaggedImplausibleAndMalformedSamples() {
        let samples = [
            Fixture.hr(t0, 60),
            Fixture.hr(t0 + 1_000, 61, quality: .outOfRange),
            Fixture.hr(t0 + 2_000, 62, quality: .deviceMarkedInvalid),
            Fixture.hr(t0 + 3_000, 63, quality: .noSensorContact),
            Fixture.hr(t0 + 4_000, 64, quality: .clockUnmapped),
            Fixture.hr(t0 + 5_000, 24),
            Fixture.hr(t0 + 6_000, 241),
            Fixture.hr(t0 + 7_000, 25),
            Fixture.hr(t0 + 8_000, 240),
            Fixture.hr(t0 + 9_000, 70, quality: [.phoneReceiveTime, .clockOffsetApplied]),
            Fixture.hr(.max, 70),
            Fixture.hr(.min, 70),
            Fixture.hr(t0 + 10_000, 0),
        ]
        let usable = HeartRateSeries.usable(samples)
        #expect(usable.map(\.bpm) == [60, 25, 240, 70])
    }

    @Test func emptyAndAllInvalidInputGiveAnEmptySeries() {
        let window = TimeRange(start: t0, end: t0 + Fixture.minute)
        let invalid = [Fixture.hr(t0, 300), Fixture.hr(t0 + 1_000, 70, quality: .noSensorContact)]
        for input in [[], invalid] {
            let series = HeartRateSeries(input)
            #expect(series.isEmpty)
            #expect(series.segments().isEmpty)
            #expect(series.coverage(in: window) == 0)
            #expect(series.timeWeightedMean(in: window) == nil)
            let summary = series.summary(in: window)
            #expect(summary.value == nil)
            #expect(summary.availability.isInsufficientData)
            expectInvariants(summary)
        }
        #expect(HeartRateSeries([]).coverage(in: TimeRange(start: t0, end: t0)) == nil)
        #expect(HeartRateSeries([]).coverage(in: TimeRange(start: .min, end: .max)) == nil)
    }

    @Test func historyWinsWithinFiveSecondsInclusive() {
        let history = Fixture.hr(t0 + 10_000, 60, source: .deviceHistory)
        let samples = [
            Fixture.hr(t0 + 4_999, 70, source: .liveVendorStream),   // 5.001 s before: kept
            Fixture.hr(t0 + 5_000, 71, source: .liveVendorStream),   // exactly 5 s before: dropped
            history,
            Fixture.hr(t0 + 12_000, 72, source: .standardHeartRateService), // dropped
            Fixture.hr(t0 + 15_000, 73, source: .liveVendorStream),  // exactly 5 s after: dropped
            Fixture.hr(t0 + 15_001, 74, source: .liveVendorStream),  // kept
            Fixture.hr(t0 + 13_000, 75, source: .backupImport),      // dropped
        ]
        let canonical = HeartRateSeries.canonical(samples)
        #expect(canonical.map(\.timestamp) == [t0 + 4_999, t0 + 10_000, t0 + 15_001])
        #expect(canonical.map(\.source) == [.liveVendorStream, .deviceHistory, .liveVendorStream])
    }

    @Test func liveBeatsStandardServiceInTheSameSecond() {
        let samples = [
            Fixture.hr(t0 + 1_700, 81, source: .standardHeartRateService), // same second as live: dropped
            Fixture.hr(t0 + 1_300, 80, source: .liveVendorStream),
            Fixture.hr(t0 + 1_300, 82, source: .standardHeartRateService), // same ms as live: dropped
            Fixture.hr(t0 + 2_100, 83, source: .standardHeartRateService), // next second, alone: kept
            Fixture.hr(t0 + 3_200, 84, source: .backupImport),
            Fixture.hr(t0 + 3_900, 85, source: .standardHeartRateService), // backup beats standard: dropped
        ]
        let canonical = HeartRateSeries.canonical(samples)
        #expect(canonical.map(\.bpm) == [80, 83, 84])
        #expect(canonical.map(\.source) == [.liveVendorStream, .standardHeartRateService, .backupImport])
    }

    @Test func flaggedHistoryNeverSuppressesUsableSamples() {
        let samples = [
            Fixture.hr(t0, 70, source: .deviceHistory, quality: .noSensorContact),
            Fixture.hr(t0 + 1_000, 72, source: .liveVendorStream),
        ]
        #expect(HeartRateSeries.canonical(samples).map(\.bpm) == [72])
    }

    @Test func canonicalIsSortedUniquePerTimestampAndOrderIndependent() {
        var samples = Fixture.hrRun(from: t0, count: 50, step: 2_000) { 60 + $0 % 7 }
        samples += Fixture.hrRun(from: t0 + 200_000, count: 30, step: 1_000, source: .liveVendorStream) { 90 + $0 % 3 }
        // Two history records at the same instant: the earliest received wins.
        samples.append(Fixture.hr(t0 + 400_000, 66, receivedAt: t0 + 500_000))
        samples.append(Fixture.hr(t0 + 400_000, 99, receivedAt: t0 + 450_000))
        let reference = HeartRateSeries.canonical(samples)
        #expect(zip(reference, reference.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        #expect(reference.last?.bpm == 99)

        var rng = SplitMix64(seed: 42)
        for _ in 0..<5 {
            #expect(HeartRateSeries.canonical(samples.shuffled(using: &rng)) == reference)
        }
    }

    @Test func segmentsSplitOnlyAtGapsLongerThanTheThreshold() {
        var samples = Fixture.hrRun(from: t0, count: 10) { _ in 60 }            // 0…9 s
        samples.append(Fixture.hr(t0 + 19_000, 61))                             // gap 10 s: same segment
        samples += Fixture.hrRun(from: t0 + 30_000, count: 3) { _ in 62 }      // gap 11 s: new segment
        let series = HeartRateSeries(samples)

        let segments = series.segments()
        #expect(segments.count == 2)
        #expect(segments.first?.firstTimestamp == t0)
        #expect(segments.first?.lastTimestamp == t0 + 19_000)
        #expect(segments.first?.samples.count == 11)
        #expect(segments.last?.firstTimestamp == t0 + 30_000)
        #expect(segments.last?.lastTimestamp == t0 + 32_000)

        #expect(series.segments(maxGapMillis: 5_000).count == 3)
        #expect(series.segments(in: TimeRange(start: t0 + 25_000, end: t0 + 40_000)).count == 1)
    }

    @Test func coverageSpansAreCappedAtFiveSeconds() {
        let window = TimeRange(start: t0, end: t0 + 60_000)
        let dense = HeartRateSeries(Fixture.hrRun(from: t0, count: 60) { _ in 60 })
        #expect(dense.coverage(in: window) == 1.0)

        let sparse = HeartRateSeries(Fixture.hrRun(from: t0, count: 6, step: 10_000) { _ in 60 })
        #expect(sparse.coverage(in: window) == 0.5)
        #expect(sparse.coverageSpans().map(\.range.durationMillis) == [5_000, 5_000, 5_000, 5_000, 5_000, 5_000])

        // 0…29 s at 1 Hz then silence: 29 one-second spans + one 5 s span.
        let gap = HeartRateSeries(Fixture.hrRun(from: t0, count: 30) { _ in 60 })
        #expect(gap.coveredMillis(in: window) == 34_000)

        // A sample 2 s before the window covers the window's first 3 s.
        let before = HeartRateSeries([Fixture.hr(t0 - 2_000, 60)])
        #expect(before.coverage(in: TimeRange(start: t0, end: t0 + 10_000)) == 0.3)
        #expect(before.coverageSpans(in: TimeRange(start: t0, end: t0 + 10_000)).map(\.range) == [TimeRange(start: t0, end: t0 + 3_000)])
    }

    @Test func meanIsTimeWeightedOverSpans() {
        // 60 bpm covers 1 s (next sample 1 s later), 120 bpm covers 5 s (no next sample).
        let series = HeartRateSeries([Fixture.hr(t0, 60), Fixture.hr(t0 + 1_000, 120)])
        let window = TimeRange(start: t0, end: t0 + 60_000)
        #expect(series.timeWeightedMean(in: window) == 110)

        let summary = series.summary(in: window)
        expectInvariants(summary)
        #expect(summary.value?.meanBPM == 110)
        #expect(summary.value?.minimumBPM == 60)
        #expect(summary.value?.maximumBPM == 120)
        #expect(summary.value?.coveredMillis == 6_000)
        #expect(summary.coverage == 0.1)
        #expect(summary.confidence == .low)
        #expect(summary.specID == MetricID.heartRateSeries)
    }
}
