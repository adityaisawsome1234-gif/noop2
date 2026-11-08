import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("HRV (RMSSD)")
struct HRVTests {
    let t0 = Fixture.t0
    let w = Fixture.minute * 5

    func range(windows: Int) -> TimeRange {
        TimeRange(start: t0, end: t0 + Int64(windows) * w)
    }

    @Test func handComputedSeriesWithConstantAmplitude() throws {
        // Every successive difference is ±40 ms, so each window's RMSSD is exactly 40 ms.
        let beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        let result = HRVAnalyzer.analyze(beats: beats, range: range(windows: 6))
        expectInvariants(result.rmssd)
        expectInvariants(result.lnRMSSD)
        #expect(result.rmssd.value == 40.0)
        #expect(result.lnRMSSD.value == 3.689)     // ln 40 = 3.68888
        #expect(result.validWindows == 6)
        #expect(result.totalWindows == 6)
        #expect(result.rmssd.coverage == 1.0)
        #expect(result.rmssd.confidence == .high)
        #expect(result.totalBeats == 1_800)
        #expect(result.acceptedBeats == 1_800)
        #expect(result.acceptedFraction == 1.0)
        #expect(result.artifacts == HRVArtifactCounts())
        #expect(result.segmentCount == 1)
        #expect(result.windows.allSatisfy { $0.successivePairs == 299 && $0.rmssd == 40.0 && $0.isValid })
        #expect(result.rmssd.specID == MetricID.hrvRMSSD)
        #expect(result.rmssd.inputs["validWindows"] == "6 of 6")
    }

    @Test func periodValueIsTheMedianOfWindowRMSSDs() {
        // Window k alternates 1000 ∓ aₖ: window RMSSDs 20, 30, 40, 50, 60, 70, 80 → median 50.
        let beats = Fixture.alternatingWindows(start: t0, amplitudes: [10, 15, 20, 25, 30, 35, 40])
        let result = HRVAnalyzer.analyze(beats: beats, range: range(windows: 7))
        #expect(result.windows.map(\.rmssd) == [20, 30, 40, 50, 60, 70, 80])
        #expect(result.rmssd.value == 50.0)
        #expect(result.lnRMSSD.value == 3.912)     // ln 50 = 3.91202
        // The pair spanning two windows is never formed, so the diagnostic raw value (which spans
        // windows but not segments) differs from the windowed one.
        #expect(result.rawRMSSD.value != nil)
    }

    @Test func ectopicBeatIsRejectedByRuleB() throws {
        var beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        // Premature beat (600 ms) followed by a compensatory pause (1400 ms + 40): timestamps after it are unchanged.
        let i = 2 * 300 + 100
        let pair = beats[i].intervalMillis + beats[i + 1].intervalMillis   // 980 + 1020
        beats[i].intervalMillis = 600
        beats[i].timestamp = beats[i - 1].timestamp + 600
        beats[i + 1].intervalMillis = pair - 600                           // 1400; its timestamp is unchanged
        let result = HRVAnalyzer.analyze(beats: beats, range: range(windows: 6))
        #expect(result.artifacts.ruleB == 2)
        #expect(result.artifacts.ruleA == 0)
        #expect(result.acceptedBeats == 1_798)
        #expect(result.windows[2].successivePairs == 296)   // three pairs touch the two rejected beats
        #expect(result.rmssd.value == 40.0)                 // unaffected
        let raw = try #require(result.rawRMSSD.value)
        #expect(raw > 40)                                   // the unfiltered diagnostic is inflated
        #expect(result.rawRMSSD.inputs["diagnosticOnly"] != nil)
        #expect(result.rawRMSSD.confidence == .low)
        #expect(result.rawRMSSD.specID == MetricID.hrvRawRMSSD)
    }

    @Test func outOfRangeIntervalsAreRejectedByRuleA() {
        var beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        beats[50].intervalMillis = 250          // below 300 ms
        beats[700].intervalMillis = 2_600       // above 2000 ms
        beats[1_200].intervalMillis = .nan      // non-finite
        let result = HRVAnalyzer.analyze(beats: beats, range: range(windows: 6))
        #expect(result.artifacts.ruleA == 3)
        #expect(result.artifacts.ruleB == 0)
        #expect(result.segmentCount == 1)       // a bad value is not a timing gap
        #expect(result.rmssd.value == 40.0)
        #expect(result.validWindows == 6)
    }

    @Test func ruleBBoundaryIsTwentyPercentInclusive() {
        // Reference median 1000 ms: ±200 ms (exactly 20 %) is accepted, 201 ms is rejected.
        let ones = Array(repeating: 1_000.0, count: 10)
        let intervals = ones + [1_200] + ones + [800] + ones + [1_201] + ones + [799] + ones
        let result = HRVAnalyzer.analyze(beats: Fixture.beats(origin: t0, intervals: intervals), range: range(windows: 1))
        #expect(result.artifacts.ruleB == 2)
        #expect(result.acceptedBeats == intervals.count - 2)
    }

    @Test func ruleBNeedsThreeAcceptedReferencesInTheSegment() {
        // The 3rd beat of a segment has only two references, so it is not checked; the 4th is.
        let early = Fixture.beats(origin: t0, intervals: [1_000, 1_000, 1_500] + Array(repeating: 1_000, count: 20))
        #expect(HRVAnalyzer.analyze(beats: early, range: range(windows: 1)).artifacts.ruleB == 0)
        let later = Fixture.beats(origin: t0, intervals: [1_000, 1_000, 1_000, 1_500] + Array(repeating: 1_000, count: 20))
        #expect(HRVAnalyzer.analyze(beats: later, range: range(windows: 1)).artifacts.ruleB == 1)
    }

    @Test func ruleBReferenceIsTheLastFiveAcceptedBeats() {
        // After three 1190 ms beats the last-five median is 1190, so 1400 (+17.6 %) is accepted; a median over
        // all accepted beats (1000) would reject it.
        let intervals = Array(repeating: 1_000.0, count: 20) + [1_190, 1_190, 1_190, 1_400] + Array(repeating: 1_190.0, count: 10)
        let result = HRVAnalyzer.analyze(beats: Fixture.beats(origin: t0, intervals: intervals), range: range(windows: 1))
        #expect(result.artifacts.ruleB == 0)
    }

    @Test func deviceFlaggedBeatsAreRejected() {
        var beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        beats[10].quality = .noSensorContact
        beats[11].quality = .deviceMarkedInvalid
        beats[12].quality = .clockUnmapped
        let result = HRVAnalyzer.analyze(beats: beats, range: range(windows: 6))
        #expect(result.artifacts.flagged == 3)
        #expect(result.artifacts.total == 3)
        #expect(result.rmssd.value == 40.0)
    }

    @Test func dropoutStartsANewSegmentAndIsNeverDifferenced() throws {
        // Segment A alternates 980/1020; after a 6 s silence segment B alternates 780/820.
        // All in-segment differences are ±40; a difference across the gap would be ≥ 160.
        var intervals: [Double] = (0..<50).map { $0 % 2 == 0 ? 980 : 1_020 }
        let a = Fixture.beats(origin: t0, intervals: intervals)
        let lastA = try #require(a.last).timestamp
        intervals = (0..<50).map { $0 % 2 == 0 ? 780 : 820 }
        let b = Fixture.beats(origin: lastA + 6_000, intervals: intervals)
        let result = HRVAnalyzer.analyze(beats: a + b, range: TimeRange(start: t0, end: t0 + 5 * w))
        #expect(result.segmentCount == 2)
        #expect(result.rawRMSSD.value == 40.0)
        #expect(result.rawRMSSD.inputs["pairs"] == "98")   // 49 + 49, none across the gap
    }

    @Test func dropoutThresholdIsIntervalPlusTwoSecondsExclusive() {
        let a = Fixture.beats(origin: t0, intervals: Array(repeating: 1_000, count: 10))
        let last = a.last?.timestamp ?? t0
        // Δt = interval + 2000 ms: same segment. Δt = interval + 2001 ms: new segment.
        let atLimit = a + [Fixture.beat(last + 3_000, 1_000, index: 10)]
        #expect(HRVAnalyzer.analyze(beats: atLimit, range: range(windows: 1)).segmentCount == 1)
        let beyond = a + [Fixture.beat(last + 3_001, 1_000, index: 10)]
        #expect(HRVAnalyzer.analyze(beats: beyond, range: range(windows: 1)).segmentCount == 2)
    }

    @Test func sourceChangeStartsANewSegment() {
        let a = Fixture.beats(origin: t0, intervals: (0..<50).map { $0 % 2 == 0 ? 980 : 1_020 })
        let lastA = a.last?.timestamp ?? t0
        // No time gap, but the next beats come from a different source.
        let b = Fixture.beats(origin: lastA, intervals: (0..<50).map { $0 % 2 == 0 ? 780 : 820 }, source: .liveVendorStream)
        let result = HRVAnalyzer.analyze(beats: a + b, range: TimeRange(start: t0, end: t0 + 5 * w))
        #expect(result.segmentCount == 2)
        #expect(result.rawRMSSD.value == 40.0)
    }

    @Test func dropoutInsideAWindowKeepsTheWindowRMSSDExact() {
        var beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        beats.removeSubrange(1_000..<1_006)   // ≈ 6 s missing inside window 3
        let result = HRVAnalyzer.analyze(beats: beats, range: range(windows: 6))
        #expect(result.segmentCount == 2)
        #expect(result.windows[3].beats == 294)
        #expect(result.windows[3].successivePairs == 292)   // 293 − 1 pair that would span the gap
        #expect(result.rmssd.value == 40.0)
    }

    @Test func inputOrderDoesNotMatter() {
        let beats = Fixture.alternatingWindows(start: t0, amplitudes: [10, 20, 30, 40, 50, 60])
        var rng = SplitMix64(seed: 7)
        let reference = HRVAnalyzer.analyze(beats: beats, range: range(windows: 6))
        #expect(HRVAnalyzer.analyze(beats: beats.reversed(), range: range(windows: 6)) == reference)
        #expect(HRVAnalyzer.analyze(beats: beats.shuffled(using: &rng), range: range(windows: 6)) == reference)
    }

    @Test func windowNeedsEightyPercentAcceptedBeats() throws {
        var beats = Fixture.alternatingWindows(start: t0, amplitudes: [20])
        for i in stride(from: 4, to: 300, by: 5) { beats[i].quality = .noSensorContact }   // 60 of 300 flagged
        let atThreshold = HRVAnalyzer.analyze(beats: beats, range: range(windows: 1))
        let window = try #require(atThreshold.windows.first)
        #expect(window.acceptedBeats == 240)
        #expect(window.isValid)                     // exactly 80 % is enough
        #expect(window.successivePairs == 180)

        beats[0].quality = .noSensorContact           // 239 of 300 accepted
        let below = try #require(HRVAnalyzer.analyze(beats: beats, range: range(windows: 1)).windows.first)
        #expect(!below.isValid)
        #expect(below.invalidReason?.contains("80%") == true)
    }

    @Test func windowNeedsOneHundredSuccessivePairs() throws {
        // 1940/1960 ms beats: 97 beats in ≈ 189 s → 96 pairs (accepted sum ≥ 180 s, 100 % accepted).
        let few = Fixture.beats(origin: t0, intervals: (0..<97).map { $0 % 2 == 0 ? 1_940 : 1_960 })
        let invalid = try #require(HRVAnalyzer.analyze(beats: few, range: range(windows: 1)).windows.first)
        #expect(invalid.successivePairs == 96)
        #expect(!invalid.isValid)
        #expect(invalid.invalidReason == "96 successive pairs; needs at least 100")

        let enough = Fixture.beats(origin: t0, intervals: (0..<101).map { $0 % 2 == 0 ? 1_940 : 1_960 })
        let valid = try #require(HRVAnalyzer.analyze(beats: enough, range: range(windows: 1)).windows.first)
        #expect(valid.successivePairs == 100)
        #expect(valid.isValid)
        #expect(valid.rmssd == 20.0)
    }

    @Test func windowNeedsThreeMinutesOfAcceptedIntervals() throws {
        // 590/610 ms beats for ≈ 170 s: plenty of pairs, but accepted intervals sum to < 180 s.
        let beats = Fixture.beats(origin: t0, intervals: (0..<283).map { $0 % 2 == 0 ? 590 : 610 })
        let window = try #require(HRVAnalyzer.analyze(beats: beats, range: range(windows: 1)).windows.first)
        #expect(window.successivePairs == 282)
        #expect(!window.isValid)
        #expect(window.invalidReason?.contains("needs at least 180 s") == true)
    }

    @Test func periodNeedsSixValidWindows() {
        let five = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 5))
        let r5 = HRVAnalyzer.analyze(beats: five, range: range(windows: 5))
        expectInvariants(r5.rmssd)
        #expect(r5.rmssd.value == nil)
        #expect(r5.rmssd.availability == .insufficientData(detail: "Needs at least 6 valid 5 min windows; have 5 of 5"))
        #expect(r5.lnRMSSD.value == nil)
        #expect(r5.rmssd.coverage == 1.0)

        let sixOfTen = HRVAnalyzer.analyze(beats: Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6)),
                                           range: range(windows: 10))
        #expect(sixOfTen.rmssd.value == 40.0)
        #expect(sixOfTen.rmssd.coverage == 0.6)
        #expect(sixOfTen.rmssd.confidence == .moderate)   // 60 % of windows valid
        #expect(sixOfTen.windows[7].invalidReason == "no beats")
    }

    @Test func trailingPartialWindowIsNotAnalysed() {
        let beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 7))
        let result = HRVAnalyzer.analyze(beats: beats, range: TimeRange(start: t0, end: t0 + 6 * w + 4 * Fixture.minute))
        #expect(result.totalWindows == 6)
        #expect(result.totalBeats == 1_800)
    }

    @Test func missingSensorEmptyAndAllInvalidInput() {
        let r = range(windows: 6)
        let unsupported = HRVAnalyzer.analyze(beats: nil, range: r)
        #expect(unsupported.rmssd.availability == .unsupportedSensor(sensor: "beat-to-beat intervals"))
        #expect(unsupported.rawRMSSD.availability.isUnsupportedSensor)

        let empty = HRVAnalyzer.analyze(beats: [], range: r)
        #expect(empty.rmssd.availability == .insufficientData(detail: "No beat-interval data in this period"))
        #expect(empty.rawRMSSD.value == nil)

        var flagged = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        for i in flagged.indices { flagged[i].quality = .noSensorContact }
        let allInvalid = HRVAnalyzer.analyze(beats: flagged, range: r)
        #expect(allInvalid.rmssd.value == nil)
        #expect(allInvalid.validWindows == 0)
        #expect(allInvalid.artifacts.flagged == 1_800)
        #expect(allInvalid.acceptedFraction == 0)

        for result in [unsupported, empty, allInvalid] {
            expectInvariants(result.rmssd)
            expectInvariants(result.lnRMSSD)
            expectInvariants(result.rawRMSSD)
        }
        let tooLong = HRVAnalyzer.analyze(beats: [], range: TimeRange(start: t0, end: t0 + 25 * Fixture.hour))
        #expect(tooLong.rmssd.availability.isLowQuality)
    }

    @Test func zeroVariabilityIsNotReportedAsAValue() {
        let constant = Fixture.beats(origin: t0 - 500, intervals: Array(repeating: 1_000, count: 1_800))
        let result = HRVAnalyzer.analyze(beats: constant, range: range(windows: 6))
        #expect(result.validWindows == 6)
        #expect(result.rmssd.value == nil)
        #expect(result.rmssd.availability.isLowQuality)
        #expect(result.lnRMSSD.value == nil)
    }

    @Test func confidenceReflectsArtifactRate() {
        var beats = Fixture.alternatingWindows(start: t0, amplitudes: Array(repeating: 20, count: 6))
        // Flag every 12th beat: 8.3 % artifacts, each window stays valid → moderate (≤ 15 %, > 5 %).
        for i in stride(from: 0, to: beats.count, by: 12) { beats[i].quality = .deviceMarkedInvalid }
        let result = HRVAnalyzer.analyze(beats: beats, range: range(windows: 6))
        #expect(result.validWindows == 6)
        #expect(result.rmssd.confidence == .moderate)
        #expect(result.rmssd.value == 40.0)
    }
}
