import Foundation
import Testing
import FormaCore
import FormaAnalytics

// =====================================================================================================
// Adversarial, specification-derived tests for FormaAnalytics.
//
// Expectations come from the module specification (sections 1–10), not from the implementation:
// boundary values, malformed / hostile inputs, property-style invariants, JSON round trips, DST and
// skipped-day calendars, and large inputs.
//
// Tests whose display name starts with "IMPLEMENTATION BUG" or "SPEC DEVIATION" fail against the current
// implementation because it does not do what the specification says; the comment above each explains why.
// =====================================================================================================

// MARK: - Self-contained fixtures (prefixed names: this target already declares `Fixture`, `SplitMix64`, …)

fileprivate enum AX {
    /// 2026-01-05T00:00:00Z (a Monday): a whole day, hour, minute and second.
    static let t0: EpochMillis = 1_767_571_200_000
    static let s: Int64 = 1_000
    static let m: Int64 = 60_000
    static let h: Int64 = 3_600_000
    static let d: Int64 = 86_400_000

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? c.timeZone
        return c
    }()

    static func calendar(_ id: String) throws -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = try #require(TimeZone(identifier: id), "time zone \(id) is not available")
        return c
    }

    static func day(_ y: Int, _ mo: Int, _ d: Int) -> LocalDay { LocalDay(year: y, month: mo, day: d) }

    /// "y-m-d" without `String(format:)`.
    static func str(_ d: LocalDay) -> String { "\(d.year)-\(d.month)-\(d.day)" }

    static func epoch(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ hour: Int = 0, _ minute: Int = 0) throws -> EpochMillis {
        let date = try #require(cal.date(from: DateComponents(year: y, month: mo, day: d, hour: hour, minute: minute)))
        return EpochMillis(date: date)
    }

    /// `count` consecutive local days ending with `last`, oldest first (Foundation calendar arithmetic).
    static func days(endingOn last: LocalDay, count: Int, calendar: Calendar) -> [LocalDay] {
        guard let start = calendar.date(from: DateComponents(year: last.year, month: last.month, day: last.day)) else { return [] }
        return (0..<count).reversed().compactMap { k in
            calendar.date(byAdding: .day, value: -k, to: start).map { LocalDay(EpochMillis(date: $0), calendar: calendar) }
        }
    }

    static func shift(_ day: LocalDay, _ n: Int, _ calendar: Calendar = AX.utc) -> LocalDay {
        guard let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let shifted = calendar.date(byAdding: .day, value: n, to: start) else { return day }
        return LocalDay(EpochMillis(date: shifted), calendar: calendar)
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }

    // Heart rate

    static func hr(_ t: EpochMillis, _ bpm: Int, _ source: MeasurementSource = .deviceHistory,
                   quality: QualityFlags = [], device: String = "band-adv") -> HeartRateSample {
        HeartRateSample(deviceID: device, timestamp: t, bpm: bpm, source: source, receivedAt: t, quality: quality)
    }

    /// `count` samples every `step` ms from `start`; bpm chosen by index.
    static func hrRun(_ start: EpochMillis, count: Int, step: Int64 = 1_000, source: MeasurementSource = .deviceHistory,
                      bpm: (Int) -> Int) -> [HeartRateSample] {
        (0..<max(0, count)).map { hr(start + Int64($0) * step, bpm($0), source) }
    }

    static func hrMax(_ bpm: Double) -> MaxHeartRate { MaxHeartRate(bpm: bpm, basis: .userOverride) }

    static func flag(_ samples: [HeartRateSample], _ q: QualityFlags) -> [HeartRateSample] {
        samples.map { var s = $0; s.quality = q; return s }
    }

    // Beat intervals

    static func beat(_ t: EpochMillis, _ interval: Double, source: MeasurementSource = .deviceHistory,
                     quality: QualityFlags = [], index: Int = 0) -> BeatInterval {
        BeatInterval(deviceID: "band-adv", timestamp: t, intervalMillis: interval, source: source, recordKey: t,
                     indexInRecord: index, receivedAt: t, timingBasis: .reconstructedFromRecordTime, quality: quality)
    }

    /// First beat at `firstAt`; every later beat lands its own interval after the previous one.
    static func beatsCumulative(firstAt: EpochMillis, intervals: [Double], source: MeasurementSource = .deviceHistory) -> [BeatInterval] {
        var out: [BeatInterval] = []
        var t = firstAt
        for (i, x) in intervals.enumerated() {
            if i > 0 { t += Int64(x.rounded()) }
            out.append(beat(t, x, source: source, index: i))
        }
        return out
    }

    /// Window k (5 min, aligned to `start`) holds 289 beats, the first 4 s after the window start, with
    /// intervals cycling 1000, 1000 + 3a, 1000, 1000 + a (a ≤ 22). Its 288 successive differences are
    /// +3a, −3a, +a, −a repeated 72 times, so the window RMSSD is exactly a·√5. The ≥ 5.6 s silence between
    /// windows exceeds interval + 2 s, so every window is its own segment and no pair spans two windows.
    static func cycleWindows(start: EpochMillis, amplitudes: [Double]) -> [BeatInterval] {
        var out: [BeatInterval] = []
        var index = 0
        for (k, a) in amplitudes.enumerated() {
            let cycle = [1_000, 1_000 + 3 * a, 1_000, 1_000 + a]
            var t = start + Int64(k) * 300_000 + 4_000
            for j in 0..<289 {
                let x = cycle[j % 4]
                if j > 0 { t += Int64(x.rounded()) }
                out.append(beat(t, x, index: index))
                index += 1
            }
        }
        return out
    }

    // Motion

    static func motion(_ t: EpochMillis, _ activity: Double, samples: Int = 100, epoch: Int64 = 60_000,
                       quality: QualityFlags = []) -> MotionEpoch {
        MotionEpoch(deviceID: "band-adv", timestamp: t, epochMillis: epoch, activity: activity, sampleCount: samples,
                    source: .deviceHistory, quality: quality)
    }

    /// One 60 s epoch per minute in `[start, end)`; nil activity = no epoch at all.
    static func motionMinutes(_ start: EpochMillis, _ end: EpochMillis, _ activity: (EpochMillis) -> Double?) -> [MotionEpoch] {
        stride(from: start, to: end, by: Int(m)).compactMap { t in activity(t).map { motion(t, $0) } }
    }
}

/// SplitMix64: deterministic PRNG for reproducible randomised tests.
fileprivate struct AdvRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Honesty invariants every MetricValue must satisfy (spec: nil value + `.none` confidence when unavailable).
fileprivate func axCheck<V>(_ m: MetricValue<V>, _ note: @autoclosure () -> String = "",
                            sourceLocation: SourceLocation = #_sourceLocation) {
    let n = note()
    if m.availability.isAvailable {
        #expect(m.value != nil, "available result without a value \(n)", sourceLocation: sourceLocation)
        #expect(m.confidence != .none, "available result with confidence .none \(n)", sourceLocation: sourceLocation)
    } else {
        #expect(m.value == nil, "unavailable result carries a value \(n)", sourceLocation: sourceLocation)
        #expect(m.confidence == .none, "unavailable result carries a confidence \(n)", sourceLocation: sourceLocation)
    }
    let spec = MetricCatalog.spec(for: m.specID)
    #expect(spec != nil, "unknown spec \(m.specID) \(n)", sourceLocation: sourceLocation)
    #expect(spec?.version == m.specVersion, "spec version mismatch \(n)", sourceLocation: sourceLocation)
    if let c = m.coverage {
        #expect(c.isFinite && c >= 0 && c <= 1 + 1e-12, "coverage \(c) out of 0…1 \(n)", sourceLocation: sourceLocation)
    }
    if let x = m.value as? Double {
        #expect(x.isFinite, "non-finite value \(n)", sourceLocation: sourceLocation)
    }
}

fileprivate func axKind(_ a: Availability) -> String {
    switch a {
    case .available: return "available"
    case .insufficientData: return "insufficientData"
    case .calibrating: return "calibrating"
    case .unsupportedSensor: return "unsupportedSensor"
    case .lowQuality: return "lowQuality"
    case .notYetSynced: return "notYetSynced"
    case .disabled: return "disabled"
    }
}

/// A type-erased summary of one MetricValue, so results of different value types can be swept together.
fileprivate struct AXFacts {
    var label: String
    var available: Bool
    var hasValue: Bool
    var confidence: Confidence
    var specKnown: Bool
    var coverageOK: Bool
    var finite: Bool
    var inputsEmpty: Bool
    var hasWindow: Bool
    var windowed: Bool

    init<V>(_ m: MetricValue<V>, _ label: String, windowed: Bool) {
        self.label = label
        available = m.availability.isAvailable
        hasValue = m.value != nil
        confidence = m.confidence
        specKnown = MetricCatalog.spec(for: m.specID)?.version == m.specVersion
        coverageOK = m.coverage.map { $0.isFinite && $0 >= 0 && $0 <= 1 + 1e-12 } ?? true
        finite = (m.value as? Double).map(\.isFinite) ?? true
        inputsEmpty = m.inputs.isEmpty
        hasWindow = m.window != nil
        self.windowed = windowed
    }
}

// MARK: - 1. Heart-rate series

@Suite("Adversarial: heart-rate series")
struct AdvHeartRateSeriesTests {
    let t0 = AX.t0

    // The integration review added `.unvalidatedField` to the module spec's four exclusion flags: a value decoded
    // from a field whose meaning is not yet validated must never enter a series or metric.
    @Test func usableExcludesExactlyTheSpecExclusionFlags() {
        // Integration also added `.nearClockDiscontinuity` (METHODOLOGY §2: records next to a clock change are excluded).
        let excluded: [QualityFlags] = [.outOfRange, .deviceMarkedInvalid, .noSensorContact, .clockUnmapped, .unvalidatedField,
                                        .nearClockDiscontinuity]
        let tolerated: [QualityFlags] = [.phoneReceiveTime, .clockOffsetApplied]
        for f in excluded {
            #expect(HeartRateSeries.usable([AX.hr(t0, 60, quality: f)]).isEmpty, "flag \(f.rawValue) must exclude")
            #expect(HeartRateSeries.usable([AX.hr(t0, 60, quality: f.union(.phoneReceiveTime))]).isEmpty)
        }
        for f in tolerated {
            #expect(HeartRateSeries.usable([AX.hr(t0, 60, quality: f)]).count == 1, "flag \(f.rawValue) is not an exclusion flag")
        }
        #expect(HeartRateSeries.usable([AX.hr(t0, 60, quality: QualityFlags(tolerated))]).count == 1)
    }

    @Test func plausibleRangeBoundsAreInclusive() {
        for bpm in [25, 26, 239, 240] {
            #expect(HeartRateSeries.usable([AX.hr(t0, bpm)]).count == 1, "\(bpm) bpm is plausible")
        }
        for bpm in [24, 241, 0, -1, -60, 1_000, Int.min, Int.max] {
            #expect(HeartRateSeries.usable([AX.hr(t0, bpm)]).isEmpty, "\(bpm) bpm is implausible")
        }
        #expect(HeartRateSeries.usable([]).isEmpty)
        #expect(HeartRateSeries.canonical([]).isEmpty)
    }

    @Test(arguments: [MeasurementSource.liveVendorStream, .standardHeartRateService])
    func historyPrecedenceWindowIsPlusMinusFiveSeconds(source: MeasurementSource) {
        let h = t0 + 10_000
        let cases: [(Int64, Bool)] = [(-5_001, true), (-5_000, false), (-4_999, false), (-1, false), (0, false),
                                      (1, false), (4_999, false), (5_000, false), (5_001, true)]
        for (offset, kept) in cases {
            let out = HeartRateSeries.canonical([AX.hr(h, 70, .deviceHistory), AX.hr(h + offset, 90, source)])
            #expect(out.contains { $0.source == source } == kept, "offset \(offset) ms")
            #expect(out.contains { $0.source == .deviceHistory && $0.timestamp == h && $0.bpm == 70 })
        }
    }

    @Test func unusableHistoryNeverSuppressesUsableSamples() {
        let out = HeartRateSeries.canonical([
            AX.hr(t0, 70, .deviceHistory, quality: .noSensorContact),
            AX.hr(t0 + 1_000, 300, .deviceHistory),                 // implausible
            AX.hr(t0 + 2_000, 80, .liveVendorStream),
            AX.hr(t0 + 3_000, 81, .standardHeartRateService),
        ])
        #expect(out.map(\.timestamp) == [t0 + 2_000, t0 + 3_000])
    }

    @Test func liveBeatsStandardOnlyInsideTheSameUTCSecond() {
        var out = HeartRateSeries.canonical([AX.hr(t0 + 1_900, 80, .liveVendorStream), AX.hr(t0 + 1_100, 70, .standardHeartRateService)])
        #expect(out.map(\.source) == [.liveVendorStream])
        out = HeartRateSeries.canonical([AX.hr(t0 + 5_000, 70, .standardHeartRateService), AX.hr(t0 + 5_999, 80, .liveVendorStream)])
        #expect(out.map(\.source) == [.liveVendorStream])
        // 1 ms apart but in different seconds: both stay.
        out = HeartRateSeries.canonical([AX.hr(t0 + 1_999, 80, .liveVendorStream), AX.hr(t0 + 2_000, 70, .standardHeartRateService)])
        #expect(out.count == 2)
        // Before the epoch: −999 ms is 23:59:59.001 and +1 ms is 00:00:00.001, different seconds.
        out = HeartRateSeries.canonical([AX.hr(-999, 80, .liveVendorStream), AX.hr(1, 70, .standardHeartRateService)])
        #expect(out.count == 2)
        out = HeartRateSeries.canonical([AX.hr(-1_500, 80, .liveVendorStream), AX.hr(-1_100, 70, .standardHeartRateService)])
        #expect(out.map(\.source) == [.liveVendorStream])
    }

    @Test func historySuppressionIsAppliedBeforeSourceRanking() {
        // The live sample is inside the history sample's ±5 s and is dropped; the standard-service sample in
        // the same UTC second is 5.5 s away (no history there) and has no surviving live rival, so it stays.
        let out = HeartRateSeries.canonical([
            AX.hr(t0, 60, .deviceHistory),
            AX.hr(t0 + 5_000, 80, .liveVendorStream),
            AX.hr(t0 + 5_500, 90, .standardHeartRateService),
        ])
        #expect(out.map(\.timestamp) == [t0, t0 + 5_500])
    }

    @Test func canonicalPropertiesOnRandomMultiSourceInput() {
        var rng = AdvRNG(seed: 0xC0FFEE)
        let sources: [MeasurementSource] = [.deviceHistory, .liveVendorStream, .standardHeartRateService]
        for _ in 0..<25 {
            var input: [HeartRateSample] = []
            for _ in 0..<Int.random(in: 0...400, using: &rng) {
                let t = t0 + Int64.random(in: 0..<120_000, using: &rng)
                let source = sources[Int.random(in: 0..<sources.count, using: &rng)]
                let q: QualityFlags = Int.random(in: 0..<10, using: &rng) == 0 ? .noSensorContact : []
                input.append(AX.hr(t, Int.random(in: 15...255, using: &rng), source, quality: q))
            }
            let out = HeartRateSeries.canonical(input)
            let usable = HeartRateSeries.usable(input)
            #expect(zip(out, out.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp }, "sorted, one per timestamp")
            #expect(out.allSatisfy { HeartRateSeries.usable([$0]).count == 1 })
            let inputSet = Set(input)
            #expect(out.allSatisfy { inputSet.contains($0) }, "never invents samples")
            #expect(HeartRateSeries.canonical(out) == out, "idempotent")
            #expect(HeartRateSeries.canonical(input.shuffled(using: &rng)) == out, "independent of input order")
            #expect(HeartRateSeries(input).samples == out)

            let historyTimes = usable.filter { $0.source == .deviceHistory }.map(\.timestamp)
            func nearHistory(_ t: EpochMillis) -> Bool { historyTimes.contains { abs($0 - t) <= 5_000 } }
            for s in out where s.source != .deviceHistory {
                #expect(!nearHistory(s.timestamp), "non-history sample within ±5 s of history")
            }
            let outByTime = Dictionary(out.map { ($0.timestamp, $0) }, uniquingKeysWith: { a, _ in a })
            for t in historyTimes {
                #expect(outByTime[t]?.source == .deviceHistory, "usable band history is never dropped")
            }
            let liveSeconds = Set(usable.filter { $0.source == .liveVendorStream && !nearHistory($0.timestamp) }
                .map { AX.floorDiv($0.timestamp, 1_000) })
            for s in out where s.source == .standardHeartRateService {
                #expect(!liveSeconds.contains(AX.floorDiv(s.timestamp, 1_000)), "live must beat standard in the same second")
            }
        }
    }

    @Test func segmentsSplitOnlyWhenTheGapExceedsTheLimit() {
        let series = HeartRateSeries([AX.hr(t0, 60), AX.hr(t0 + 10_000, 61), AX.hr(t0 + 20_001, 62)])
        let segs = series.segments()
        #expect(segs.map { $0.samples.map(\.bpm) } == [[60, 61], [62]])
        #expect(segs.first?.firstTimestamp == t0)
        #expect(segs.first?.lastTimestamp == t0 + 10_000)
        #expect(series.segments(maxGapMillis: 0).count == 3)
        #expect(series.segments(maxGapMillis: -5).count == 3)
        #expect(series.segments(maxGapMillis: .min).count == 3)
        #expect(series.segments(maxGapMillis: .max).count == 1)
        #expect(HeartRateSeries([]).segments().isEmpty)
        #expect(HeartRateSeries([AX.hr(t0, 60)]).segments().count == 1)
        // An unusable sample never bridges a gap on the chart.
        let bridged = HeartRateSeries([AX.hr(t0, 60), AX.hr(t0 + 8_000, 60, quality: .noSensorContact), AX.hr(t0 + 16_000, 60)])
        #expect(bridged.segments().count == 2)
    }

    @Test func segmentsPartitionTheSeries() {
        var rng = AdvRNG(seed: 42)
        for _ in 0..<20 {
            var samples: [HeartRateSample] = []
            var t = t0
            for _ in 0..<300 {
                t += Int64.random(in: 1...25_000, using: &rng)
                samples.append(AX.hr(t, 70))
            }
            let series = HeartRateSeries(samples)
            let gap = Int64.random(in: 0...20_000, using: &rng)
            let segs = series.segments(maxGapMillis: gap)
            #expect(segs.flatMap(\.samples) == series.samples)
            for seg in segs {
                #expect(!seg.samples.isEmpty)
                #expect(zip(seg.samples, seg.samples.dropFirst()).allSatisfy { $1.timestamp - $0.timestamp <= gap })
                #expect(seg.firstTimestamp == seg.samples.first?.timestamp)
                #expect(seg.lastTimestamp == seg.samples.last?.timestamp)
            }
            for (a, b) in zip(segs, segs.dropFirst()) {
                #expect(b.firstTimestamp - a.lastTimestamp > gap)
            }
        }
    }

    @Test func coverageModelHandExamples() throws {
        let one = HeartRateSeries([AX.hr(t0, 60)])
        #expect(one.coverage(in: TimeRange(start: t0, end: t0 + 10_000)) == 0.5)
        #expect(one.coverage(in: TimeRange(start: t0 - 5_000, end: t0 + 5_000)) == 0.5)
        #expect(one.coverage(in: TimeRange(start: t0 + 5_000, end: t0 + 10_000)) == 0)
        #expect(one.coverage(in: TimeRange(start: t0 + 4_999, end: t0 + 5_000)) == 1)
        #expect(HeartRateSeries([AX.hr(t0, 60), AX.hr(t0 + 3_000, 60)]).coverage(in: TimeRange(start: t0, end: t0 + 20_000)) == 0.4)
        #expect(HeartRateSeries([AX.hr(t0, 60), AX.hr(t0 + 20_000, 60)]).coverage(in: TimeRange(start: t0, end: t0 + 25_000)) == 0.4)
        let dense = HeartRateSeries(AX.hrRun(t0, count: 60) { _ in 60 })
        #expect(dense.coverage(in: TimeRange(start: t0, end: t0 + 60_000)) == 1)
        #expect(dense.coverage(in: TimeRange(start: t0, end: t0 + 64_000)) == 1)
        let c65 = try #require(dense.coverage(in: TimeRange(start: t0, end: t0 + 65_000)))
        #expect(abs(c65 - 64.0 / 65.0) < 1e-12)
        // An unusable neighbour does not shorten the span of a usable sample.
        let flaggedNext = HeartRateSeries([AX.hr(t0, 60), AX.hr(t0 + 1_000, 90, quality: .noSensorContact)])
        #expect(flaggedNext.coverage(in: TimeRange(start: t0, end: t0 + 5_000)) == 1)
        // A sample removed by the history merge does not shorten the history sample's span either.
        let merged = HeartRateSeries([AX.hr(t0, 60, .deviceHistory), AX.hr(t0 + 1_000, 90, .liveVendorStream)])
        #expect(merged.coverage(in: TimeRange(start: t0, end: t0 + 5_000)) == 1)
        #expect(merged.timeWeightedMean(in: TimeRange(start: t0, end: t0 + 5_000)) == 60)
        // An empty (or reversed, hence empty) window has no defined coverage: nil, never 0.
        #expect(one.coverage(in: TimeRange(start: t0, end: t0)) == nil)
        #expect(one.coverage(in: TimeRange(start: t0 + 10, end: t0)) == nil)
        #expect(HeartRateSeries([]).coverage(in: TimeRange(start: t0, end: t0 + 1_000)) == 0)
    }

    @Test func coverageIsAdditiveBoundedAndMatchesTheSpans() {
        var rng = AdvRNG(seed: 7)
        for _ in 0..<30 {
            var samples: [HeartRateSample] = []
            for _ in 0..<Int.random(in: 0...200, using: &rng) {
                samples.append(AX.hr(t0 + Int64.random(in: 0..<600_000, using: &rng), Int.random(in: 40...200, using: &rng)))
            }
            let series = HeartRateSeries(samples)
            let cuts = (0..<3).map { _ in t0 - 10_000 + Int64.random(in: 0..<630_000, using: &rng) }.sorted()
            let ab = series.coveredMillis(in: TimeRange(start: cuts[0], end: cuts[1]))
            let bc = series.coveredMillis(in: TimeRange(start: cuts[1], end: cuts[2]))
            let ac = series.coveredMillis(in: TimeRange(start: cuts[0], end: cuts[2]))
            #expect(ab + bc == ac, "covered time is additive over adjacent windows")
            if let c = series.coverage(in: TimeRange(start: cuts[0], end: cuts[2])) {
                #expect(c >= 0 && c <= 1)
            }
            let spans = series.coverageSpans()
            #expect(spans.count == series.samples.count)
            for (i, span) in spans.enumerated() {
                let s = series.samples[i]
                let next = i + 1 < series.samples.count ? series.samples[i + 1].timestamp : Int64.max
                #expect(span.range.start == s.timestamp)
                #expect(span.range.end == min(s.timestamp + 5_000, next), "[t, t + min(gap to next, 5 s))")
                #expect(span.bpm == s.bpm)
            }
            let hull = TimeRange(start: t0 - 20_000, end: t0 + 700_000)
            #expect(series.coveredMillis(in: hull) == spans.reduce(Int64(0)) { $0 + $1.range.durationMillis })
        }
    }

    @Test func hostileHeartRateInputsAreRejectedWithoutTrapping() {
        let extremes: [EpochMillis] = [.min, .min + 1, -(1 << 52) - 1, -1, 0, 1, (1 << 52) + 1, .max - 1, .max]
        var samples: [HeartRateSample] = []
        for t in extremes {
            for bpm in [Int.min, -1, 0, 60, 240, 241, Int.max] { samples.append(AX.hr(t, bpm)) }
        }
        for source in MeasurementSource.allCases {
            samples.append(AX.hr(.max, 60, source))
            samples.append(AX.hr(.min, 60, source))
        }
        let series = HeartRateSeries(samples)
        #expect(series.samples.allSatisfy { HeartRateSample.plausibleRange.contains($0.bpm) })
        _ = series.segments(maxGapMillis: .min)
        _ = series.segments(maxGapMillis: .max)
        let hrMax = AX.hrMax(190)
        let zones = HeartRateZones(maxHeartRate: hrMax)
        let ranges = [TimeRange(start: .min, end: .max), TimeRange(start: .max - 1, end: .max), TimeRange(start: .min, end: .min + 1),
                      TimeRange(start: 0, end: 1), TimeRange(start: .max, end: .min), TimeRange(start: t0, end: t0 + AX.h)]
        for r in ranges {
            _ = series.segments(in: r)
            _ = series.coverage(in: r)
            _ = series.coverageSpans(in: r)
            _ = series.timeWeightedMean(in: r)
            axCheck(series.summary(in: r), "summary \(r)")
            let w = WorkoutAnalyzer.summarize(range: r, samples: samples, zones: zones)
            axCheck(w.meanHeartRate, "\(r)")
            axCheck(w.maxHeartRate, "\(r)")
            axCheck(w.timeInZones, "\(r)")
            axCheck(w.edwardsTRIMP, "\(r)")
            axCheck(RestingHeartRateEstimator.estimate(sleepWindow: r, samples: samples).restingHeartRate, "\(r)")
            axCheck(TrainingLoad.workoutLoad(range: r, samples: samples, hrMax: hrMax), "\(r)")
            axCheck(TrainingLoad.banisterTRIMP(range: r, samples: samples, hrMax: hrMax, restingHeartRate: 50, sex: .female), "\(r)")
            let sleep = SleepSummary.fromConfirmedWindow(r, motion: [], heartRate: samples)
            axCheck(sleep.timeInBed, "\(r)")
            axCheck(sleep.meanHeartRate, "\(r)")
            let hrv = HRVAnalyzer.analyze(beats: [], range: r)
            axCheck(hrv.rmssd, "\(r)")
        }
        axCheck(TrainingLoad.dailyLoad(day: AX.day(1970, 1, 1), calendar: AX.utc, samples: samples, hrMax: hrMax))
    }

    @Test(.timeLimit(.minutes(3)))
    func aDayOfTripleSourceOneHertzDataIsMergedAndAnalysed() throws {
        let day = AX.t0
        var samples: [HeartRateSample] = []
        samples.reserveCapacity(3 * 86_400)
        for k in 0..<86_400 {
            let t = day + Int64(k) * 1_000
            samples.append(AX.hr(t, 55 + k % 20, .deviceHistory))
            samples.append(AX.hr(t + 300, 90, .liveVendorStream))
            samples.append(AX.hr(t + 600, 95, .standardHeartRateService))
        }
        let series = HeartRateSeries(samples)
        #expect(series.samples.count == 86_400)
        #expect(series.samples.allSatisfy { $0.source == .deviceHistory })
        #expect(series.coverage(in: TimeRange(start: day, end: day + AX.d)) == 1)
        // bpm 55…74 with HRmax 100: per 20 s, 5 s × 1 + 10 s × 2 + 5 s × 3 = 40 weighted s → 2880 weighted min/day.
        let load = TrainingLoad.dailyLoad(day: AX.day(2026, 1, 5), calendar: AX.utc, samples: samples, hrMax: AX.hrMax(100))
        axCheck(load)
        let value = try #require(load.value)
        #expect(abs(value - 2_880) < 0.051)
        // Every 5-min window holds 15 whole 20-s cycles, so the lowest 5-min mean is the cycle mean, 64.5 bpm.
        let rhr = RestingHeartRateEstimator.estimate(sleepWindow: TimeRange(start: day, end: day + 8 * AX.h), samples: samples)
        #expect(rhr.restingHeartRate.value == 64.5)
    }
}

// MARK: - 2. Zones, HRmax and workouts

@Suite("Adversarial: zones, HRmax and workouts")
struct AdvZonesWorkoutTests {
    let w = AX.t0 + 10 * AX.h

    @Test func everyIntegerHeartRateLandsInTheZoneGivenByExactArithmetic() throws {
        // Zone k (1…5) starts at (k + 4)/10 × HRmax; compare 10·bpm with (k + 4)·HRmax in exact integers.
        for hrMax in 100...240 {
            let t = try #require(HeartRateZones(maxHeartRate: AX.hrMax(Double(hrMax))).thresholds().value)
            for bpm in 30...260 {
                let expected = (1...5).filter { 10 * bpm >= ($0 + 4) * hrMax }.count
                #expect(t.zone(forBPM: Double(bpm)) == expected, "HRmax \(hrMax), \(bpm) bpm")
            }
        }
        #expect(HeartRateZones.label(forZone: 0) == "below zones")
        #expect(HeartRateZones(maxHeartRate: AX.hrMax(200)).zone(forBPM: 99.999) == 0)
        #expect(HeartRateZones(maxHeartRate: AX.hrMax(200)).zone(forBPM: 100) == 1)
    }

    @Test func karvonenBoundsAreRestPlusFractionOfReserve() throws {
        let zones = HeartRateZones(model: .heartRateReserve, maxHeartRate: AX.hrMax(190), restingHeartRate: 50)
        let t = try #require(zones.thresholds().value)
        let expected: [Double] = [120, 134, 148, 162, 176]   // 50 + {0.5 … 0.9} × 140
        #expect(t.lowerBoundsBPM.count == 5)
        for (a, b) in zip(t.lowerBoundsBPM, expected) { #expect(abs(a - b) < 1e-9) }
        for (bpm, zone) in [(119.0, 0), (120, 1), (133, 1), (134, 2), (175, 4), (176, 5), (230, 5)] {
            #expect(zones.zone(forBPM: bpm) == zone, "\(bpm) bpm")
        }
        // Without a usable resting heart rate there are no reserve zones (never a guessed or negative reserve).
        let badRests: [Double?] = [nil, .nan, .infinity, -.infinity, -10, 0, 190, 200, 1e308]
        for rest in badRests {
            let z = HeartRateZones(model: .heartRateReserve, maxHeartRate: AX.hrMax(190), restingHeartRate: rest)
            let r = z.thresholds()
            axCheck(r)
            #expect(r.value == nil, "resting \(String(describing: rest))")
            #expect(z.zone(forBPM: 150) == nil)
        }
        let viaProfile = HeartRateZones.resolve(profile: UserProfile(maxHeartRateOverride: 190, restingHeartRateOverride: 50),
                                                asOf: AX.t0, calendar: AX.utc, model: .heartRateReserve)
        #expect(viaProfile.thresholds().value?.lowerBoundsBPM.first.map { abs($0 - 120) < 1e-9 } == true)
    }

    @Test func invalidZoneConfigurationsNeverTrap() {
        let configs: [[Double]] = [[], [.nan], [-0.5, 0.5], [0, 0.5], [0.5, 1.5], [0.6, 0.5], [0.5, 0.5],
                                   Array(repeating: 0.5, count: 50), [.infinity], [1e-300]]
        for b in configs {
            let z = HeartRateZones(boundaries: b, maxHeartRate: AX.hrMax(190))
            axCheck(z.thresholds(), "\(b)")
            _ = z.zone(forBPM: 150)
            let s = WorkoutAnalyzer.summarize(range: TimeRange(start: w, end: w + 600_000),
                                              samples: AX.hrRun(w, count: 600) { _ in 150 }, zones: z)
            axCheck(s.timeInZones, "\(b)")
        }
        for bad in [0.0, -5, .nan, .infinity, -.infinity] {
            let z = HeartRateZones(maxHeartRate: MaxHeartRate(bpm: bad, basis: .userOverride))
            #expect(z.thresholds().value == nil, "HRmax \(bad)")
            #expect(TrainingLoad.workoutLoad(range: TimeRange(start: w, end: w + 600_000),
                                             samples: AX.hrRun(w, count: 600) { _ in 150 },
                                             hrMax: MaxHeartRate(bpm: bad, basis: .userOverride)).value == nil)
        }
    }

    @Test func maxHeartRatePrecedence() throws {
        let asOf = AX.t0 + 150 * AX.d   // 2026-06-04
        let both = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990, maxHeartRateOverride: 195), asOf: asOf, calendar: AX.utc)
        axCheck(both)
        #expect(both.value?.bpm == 195)
        #expect(both.value?.basis == .userOverride)
        let age = try #require(MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: asOf, calendar: AX.utc).value)
        #expect(abs(age.bpm - 182.8) < 1e-9)      // 208 − 0.7 × 36
        #expect(age.label == "estimated from age")
        let none = MaxHeartRateResolver.resolve(profile: UserProfile(), asOf: asOf, calendar: AX.utc)
        axCheck(none)
        #expect(none.value == nil)
        #expect(none.availability.explanation.contains("Set your max heart rate or birth year"))
        // A nonsensical override is never used (and HRmax never becomes 0 or negative).
        for bad in [0, -1, Int.min] {
            let r = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990, maxHeartRateOverride: bad), asOf: asOf, calendar: AX.utc)
            axCheck(r)
            #expect(r.value.map { abs($0.bpm - 182.8) < 1e-9 } ?? true, "override \(bad) falls back to the age estimate")
            #expect(MaxHeartRateResolver.resolve(profile: UserProfile(maxHeartRateOverride: bad), asOf: asOf, calendar: AX.utc).value == nil)
        }
        // Implausible birth years never produce a negative, zero or absurd HRmax.
        for year in [Int.min, -5, 0, 1800, 2020, 2026, 2030, Int.max] {
            let r = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: year), asOf: asOf, calendar: AX.utc)
            axCheck(r, "birth year \(year)")
            if let v = r.value { #expect(v.bpm > 100 && v.bpm <= 208, "birth year \(year) → \(v.bpm)") }
        }
        #expect(HeartRateZones(maxHeartRate: nil).thresholds().value == nil)
        let unresolved = HeartRateZones.resolve(profile: UserProfile(), asOf: asOf, calendar: AX.utc)
        #expect(unresolved.thresholds().availability.explanation.contains("Set your max heart rate or birth year"))
    }

    @Test func ageUsesTheCalendarsLocalYearAroundNewYear() throws {
        // 2026-01-01T03:00:00Z is still 2025-12-31 in Los Angeles.
        let asOf: EpochMillis = 1_767_236_400_000
        let la = try AX.calendar("America/Los_Angeles")
        let inUTC = try #require(MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: asOf, calendar: AX.utc).value)
        let inLA = try #require(MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: asOf, calendar: la).value)
        #expect(abs(inUTC.bpm - 182.8) < 1e-9)   // age 36
        #expect(abs(inLA.bpm - 183.5) < 1e-9)    // age 35
    }

    @Test func birthYearIsGregorianWhateverCalendarIsPassed() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(secondsFromGMT: 0) ?? buddhist.timeZone
        let v = try #require(MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: AX.t0 + 150 * AX.d,
                                                          calendar: buddhist).value)
        #expect(abs(v.bpm - 182.8) < 1e-9)
    }

    @Test func workoutValuesNeedFiftyPercentCoverageInclusive() throws {
        let range = TimeRange(start: w, end: w + 600_000)
        let zones = HeartRateZones(maxHeartRate: AX.hrMax(200))
        // 296 samples at 1 Hz: 295 one-second spans + a final 5-s span = exactly 300 s = 50 %.
        let exact = AX.hrRun(w, count: 296) { _ in 120 }
        let ok = WorkoutAnalyzer.summarize(range: range, samples: exact, zones: zones)
        #expect(ok.coverage == 0.5)
        #expect(ok.durationMillis == 600_000)
        #expect(ok.meanHeartRate.value == 120)
        #expect(ok.maxHeartRate.value == 120)
        #expect(ok.timeInZones.value?.millis(inZone: 2) == 300_000)    // 60 % of 200 is the inclusive start of zone 2
        #expect(ok.timeInZones.value?.totalMillis == 300_000)
        let trimp = try #require(ok.edwardsTRIMP.value)
        #expect(abs(trimp - 10) < 1e-9)                                 // 5 min × weight 2
        // One sample fewer: 299 s (49.8 %) → every optional value withheld, each with a reason.
        let short = WorkoutAnalyzer.summarize(range: range, samples: Array(exact.dropLast()), zones: zones)
        #expect(short.meanHeartRate.value == nil)
        #expect(short.maxHeartRate.value == nil)
        #expect(short.timeInZones.value == nil)
        #expect(short.edwardsTRIMP.value == nil)
        for a in [short.meanHeartRate.availability, short.maxHeartRate.availability, short.timeInZones.availability,
                  short.edwardsTRIMP.availability] {
            #expect(!a.isAvailable)
            #expect(!a.explanation.isEmpty)
        }
        axCheck(short.meanHeartRate)
        axCheck(short.maxHeartRate)
        #expect(short.durationMillis == 600_000)
        #expect(abs((short.coverage ?? -1) - 299.0 / 600.0) < 1e-12)
    }

    @Test func meanIsTimeWeightedAndMaxIgnoresUnusableAndOutsideSamples() {
        let samples = [
            AX.hr(w - 1_000, 180),                              // before the workout (its span ends at the start)
            AX.hr(w, 100), AX.hr(w + 1_000, 150),
            AX.hr(w + 2_000, 200, quality: .noSensorContact),
            AX.hr(w + 3_000, 230, quality: .outOfRange),
            AX.hr(w + 4_000, 250),                              // implausible
            AX.hr(w + 5_000, 100),
            AX.hr(w + 10_000, 239),                             // at the exclusive end
        ]
        let s = WorkoutAnalyzer.summarize(range: TimeRange(start: w, end: w + 10_000), samples: samples,
                                          zones: HeartRateZones(maxHeartRate: AX.hrMax(200)))
        #expect(s.coverage == 1)
        #expect(s.meanHeartRate.value == 120)     // (100·1 + 150·4 + 100·5) / 10 s; the unweighted mean is 116.7
        #expect(s.maxHeartRate.value == 150)
        #expect(s.usableSampleCount == 3)
        #expect(s.durationMillis == 10_000)
    }

    @Test func timeInZonesComesFromCoverageSpansAndSumsToCoveredTime() throws {
        let blocks = [99, 100, 139, 140, 179, 180]                   // zones 0…5 with HRmax 200
        var samples: [HeartRateSample] = []
        for (b, bpm) in blocks.enumerated() { samples += AX.hrRun(w + Int64(b) * 300_000, count: 300) { _ in bpm } }
        let range = TimeRange(start: w, end: w + 1_800_000)
        let zones = HeartRateZones(maxHeartRate: AX.hrMax(200))
        let full = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: zones)
        let d = try #require(full.timeInZones.value)
        #expect(d.millis == [300_000, 300_000, 300_000, 300_000, 300_000, 300_000])
        #expect(d.millis(inZone: 6) == nil)
        #expect(full.edwardsTRIMP.value == 75)                       // 5 min × (0 + 1 + 2 + 3 + 4 + 5)
        // A 20-s hole inside the zone-2 block: the sample before it still covers 5 s, so 16 s are lost.
        let holed = samples.filter { !($0.timestamp >= w + 720_000 && $0.timestamp < w + 740_000) }
        let gap = WorkoutAnalyzer.summarize(range: range, samples: holed, zones: zones)
        let g = try #require(gap.timeInZones.value)
        #expect(g.millis(inZone: 2) == 284_000)
        #expect(g.totalMillis == 1_784_000)
        #expect(abs((gap.coverage ?? 0) * 1_800_000 - 1_784_000) < 1e-6)
        let trimp = try #require(gap.edwardsTRIMP.value)
        #expect(abs(trimp - (75 - 16.0 / 60 * 2)) < 0.051)
        // Heart-rate-reserve display zones do not change Edwards load (always %HRmax).
        let hrr = WorkoutAnalyzer.summarize(range: range, samples: samples,
                                            zones: HeartRateZones(model: .heartRateReserve, maxHeartRate: AX.hrMax(200), restingHeartRate: 60))
        #expect(hrr.edwardsTRIMP.value == 75)
        #expect(hrr.timeInZones.value != d)
        #expect(hrr.timeInZones.value?.totalMillis == 1_800_000)
    }

    @Test func workoutWithoutUsableHeartRateWithholdsEverything() {
        let range = TimeRange(start: w, end: w + 600_000)
        let zones = HeartRateZones(maxHeartRate: AX.hrMax(190))
        let flagged = AX.flag(AX.hrRun(w, count: 600) { _ in 120 }, .noSensorContact)
        let implausible = AX.hrRun(w, count: 600) { _ in 0 }
        for samples in [[], flagged, implausible] {
            let s = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: zones)
            #expect(s.meanHeartRate.value == nil)
            #expect(s.maxHeartRate.value == nil)
            #expect(s.timeInZones.value == nil)
            #expect(s.edwardsTRIMP.value == nil)
            #expect(!s.meanHeartRate.availability.isAvailable && !s.meanHeartRate.availability.explanation.isEmpty)
            #expect(s.usableSampleCount == 0)
            axCheck(s.meanHeartRate)
            axCheck(s.edwardsTRIMP)
        }
        let empty = WorkoutAnalyzer.summarize(range: TimeRange(start: w, end: w), samples: AX.hrRun(w, count: 10) { _ in 120 }, zones: zones)
        #expect(empty.meanHeartRate.value == nil)
        #expect(empty.coverage == nil)
        let reversed = WorkoutAnalyzer.summarize(range: TimeRange(start: w + 600_000, end: w), samples: AX.hrRun(w, count: 600) { _ in 120 }, zones: zones)
        #expect(reversed.meanHeartRate.value == nil)
    }
}

// MARK: - 8. Training load

@Suite("Adversarial: training load")
struct AdvTrainingLoadTests {
    let w = AX.t0 + 10 * AX.h

    @Test func edwardsHandExampleAndBandEdges() throws {
        var samples: [HeartRateSample] = []
        for (k, bpm) in [110, 130, 150, 170, 190].enumerated() { samples += AX.hrRun(w + Int64(k) * 600_000, count: 600) { _ in bpm } }
        let load = TrainingLoad.workoutLoad(range: TimeRange(start: w, end: w + 3_000_000), samples: samples, hrMax: AX.hrMax(200))
        axCheck(load)
        #expect(load.value == 150)                                     // 10 min × (1 + 2 + 3 + 4 + 5)
        let at50 = TrainingLoad.workoutLoad(range: TimeRange(start: w, end: w + 600_000), samples: AX.hrRun(w, count: 600) { _ in 100 },
                                            hrMax: AX.hrMax(200))
        #expect(at50.value == 10)                                      // 50 % is the inclusive start of the weight-1 band
        let below = TrainingLoad.workoutLoad(range: TimeRange(start: w, end: w + 600_000), samples: AX.hrRun(w, count: 600) { _ in 99 },
                                             hrMax: AX.hrMax(200))
        #expect(below.value == 0)                                      // a measured zero, not "unknown"
        #expect(below.availability.isAvailable)
        let noMax = TrainingLoad.workoutLoad(range: TimeRange(start: w, end: w + 3_000_000), samples: samples, hrMax: nil)
        axCheck(noMax)
        #expect(noMax.value == nil)
        #expect(noMax.availability.explanation.contains("Set your max heart rate or birth year"))
        #expect(MetricCatalog.spec(for: load.specID)?.name == "Forma Load (Edwards TRIMP)")
    }

    @Test func perWorkoutLoadIsTheSameWhicheverPathComputesIt() {
        var rng = AdvRNG(seed: 11)
        for _ in 0..<10 {
            var samples: [HeartRateSample] = []
            var t = w - 30_000
            while t < w + AX.h + 30_000 {
                if Int.random(in: 0..<200, using: &rng) == 0 { t += Int64.random(in: 5_000...300_000, using: &rng) }
                samples.append(AX.hr(t, Int.random(in: 70...200, using: &rng)))
                t += Int64.random(in: 500...2_000, using: &rng)
            }
            let range = TimeRange(start: w, end: w + AX.h)
            let summary = WorkoutAnalyzer.summarize(range: range, samples: samples, zones: HeartRateZones(maxHeartRate: AX.hrMax(195)))
            let direct = TrainingLoad.workoutLoad(range: range, samples: samples, hrMax: AX.hrMax(195))
            #expect(summary.edwardsTRIMP == direct)
            axCheck(direct)
            if let d = summary.timeInZones.value, let cov = summary.coverage {
                #expect(abs(Double(d.totalMillis) - cov * Double(range.durationMillis)) < 1e-6, "zone time = covered time")
            }
        }
    }

    @Test func dailyLoadHandExampleWithBelowZoneFiller() {
        var samples = AX.hrRun(AX.t0, count: 7 * 3_600) { _ in 80 }                 // 7 h below 50 % of 200
        let blocksStart = AX.t0 + 8 * AX.h
        for (k, bpm) in [110, 130, 150, 170, 190].enumerated() {
            samples += AX.hrRun(blocksStart + Int64(k) * 600_000, count: 600) { _ in bpm }
        }
        samples.append(AX.hr(blocksStart + 3_000_000, 80))                          // closes the last block's span
        let load = TrainingLoad.dailyLoad(day: AX.day(2026, 1, 5), calendar: AX.utc, samples: samples, hrMax: AX.hrMax(200))
        axCheck(load)
        #expect(load.value == 150)
        #expect(load.window == TimeRange(start: AX.t0, end: AX.t0 + AX.d))
        let withoutMax = TrainingLoad.dailyLoad(day: AX.day(2026, 1, 5), calendar: AX.utc, samples: samples, hrMax: nil)
        #expect(withoutMax.value == nil)
        // Malformed days never trap and never yield a value.
        for bad in [AX.day(2026, 2, 30), AX.day(2026, 13, 1), AX.day(2026, 0, 0), AX.day(Int.max, Int.max, Int.max), AX.day(Int.min, 1, 1)] {
            let r = TrainingLoad.dailyLoad(day: bad, calendar: AX.utc, samples: samples, hrMax: AX.hrMax(200))
            axCheck(r)
            #expect(r.value == nil, "\(bad.year)-\(bad.month)-\(bad.day)")
        }
    }

    @Test func dailyLoadCoverageUsesTheTrueLocalDayLength() throws {
        let ny = try AX.calendar("America/New_York")
        // 2026-03-08 lasts 23 h in New York: 30 % = 6.9 h = 24,840 s (only 28.75 % of a 24-h day).
        let springStart = try AX.epoch(ny, 2026, 3, 8)
        let spring = TrainingLoad.dailyLoad(day: AX.day(2026, 3, 8), calendar: ny,
                                            samples: AX.hrRun(springStart, count: 24_836) { _ in 110 }, hrMax: AX.hrMax(200))
        #expect(spring.window?.durationMillis == 23 * AX.h)
        let springValue = try #require(spring.value, "exactly 30 % of the 23-h local day must be enough")
        #expect(abs(springValue - 414) < 0.051)                         // 414 min × weight 1
        // 2026-11-01 lasts 25 h: 7.3 h of heart rate is 29.2 % (it would be 30.4 % of a 24-h day).
        let fallStart = try AX.epoch(ny, 2026, 11, 1)
        let fall = TrainingLoad.dailyLoad(day: AX.day(2026, 11, 1), calendar: ny,
                                          samples: AX.hrRun(fallStart, count: 26_276) { _ in 110 }, hrMax: AX.hrMax(200))
        #expect(fall.window?.durationMillis == 25 * AX.h)
        #expect(fall.value == nil)
        axCheck(fall)
    }

    // IMPLEMENTATION BUG: where a DST change skips local midnight (e.g. America/Santiago 2026-09-06, Asia/Beirut
    // 2026-03-29, America/Havana 2026-03-08, Africa/Cairo 2026-04-24), the local day starts at 01:00 and lasts
    // 23 h. The day range ends at "start + 1 day" (01:00 the next day) instead of the next local midnight, so the
    // daily windows overlap by one hour and that hour's heart rate is counted in two days' Forma Load.
    @Test("IMPLEMENTATION BUG: daily load windows must tile the timeline when DST skips midnight")
    func dailyWindowsTileTheTimelineOnMidnightDSTChanges() throws {
        let zones = ["America/Santiago", "America/Havana", "Asia/Beirut", "Africa/Cairo", "America/Asuncion",
                     "America/New_York", "Europe/London", "Australia/Lord_Howe", "Pacific/Apia", "UTC"]
        var problems: [String] = []
        for id in zones {
            let cal = try AX.calendar(id)
            let jan1 = try #require(cal.date(from: DateComponents(year: 2026, month: 1, day: 1)))
            var previous: (day: LocalDay, window: TimeRange)?
            for offset in 0..<366 {
                guard let date = cal.date(byAdding: .day, value: offset, to: jan1) else { continue }
                let day = LocalDay(EpochMillis(date: date), calendar: cal)
                let window = try #require(TrainingLoad.dailyLoad(day: day, calendar: cal, samples: [], hrMax: AX.hrMax(190)).window)
                if let p = previous, p.window.end != window.start {
                    problems.append("\(id): \(AX.str(p.day)) ends at \(p.window.end) but \(AX.str(day)) starts at \(window.start)")
                }
                if window.durationMillis > 25 * AX.h || window.durationMillis < 23 * AX.h {
                    problems.append("\(id): \(AX.str(day)) lasts \(window.durationMillis) ms")
                }
                previous = (day, window)
            }
        }
        #expect(problems.isEmpty, "\(problems)")
        // The consequence: one hour of 190 bpm right after midnight on 2026-09-07 (Santiago) counts in both days.
        let santiago = try AX.calendar("America/Santiago")
        let sept7 = try AX.epoch(santiago, 2026, 9, 7)
        let hour = AX.hrRun(sept7, count: 3_600) { _ in 190 }
        let wrongDay = TrainingLoad.dailyLoad(day: AX.day(2026, 9, 6), calendar: santiago, samples: hour, hrMax: AX.hrMax(200))
        #expect(wrongDay.window.map { $0.end <= sept7 } ?? true, "2026-09-06 must end at the next local midnight")
        // The same day range is used for trend, baseline and readiness windows.
        let one: [LocalDay: Double?] = [AX.day(2026, 9, 6): 1]
        let trendWindow = TrendAnalyzer.summary(of: one, period: .days7, endingOn: AX.day(2026, 9, 6), calendar: santiago).statistics.window
        #expect(trendWindow.map { $0.end <= sept7 } ?? true, "the 7-day trend ending 2026-09-06 overruns into 2026-09-07")
        let readinessWindow = ReadinessCalculator.compute(day: AX.day(2026, 9, 6), calendar: santiago, lnRMSSD: one,
                                                          restingHeartRate: [:], sleepDurationMinutes: [:]).composite.window
        #expect(readinessWindow.map { $0.end <= sept7 } ?? true, "the readiness window of 2026-09-06 overruns into 2026-09-07")
    }

    @Test func banisterNeverAssumesSexAndFollowsThePublishedWeighting() throws {
        let range = TimeRange(start: w, end: w + 1_800_000)
        let samples = AX.hrRun(w, count: 1_800) { _ in 125 }
        let hrMax = AX.hrMax(200)
        // x = (125 − 50) / (200 − 50) = 0.5 for 30 min.
        let male = try #require(TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax, restingHeartRate: 50, sex: .male).value)
        #expect(abs(male - 30 * 0.5 * 0.64 * exp(1.92 * 0.5)) < 0.06)
        let female = try #require(TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax, restingHeartRate: 50, sex: .female).value)
        #expect(abs(female - 30 * 0.5 * 0.86 * exp(1.67 * 0.5)) < 0.06)
        let unspecified = TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax, restingHeartRate: 50, sex: .unspecified)
        axCheck(unspecified)
        #expect(unspecified.value == nil)
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax, restingHeartRate: nil, sex: .male).value == nil)
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: nil, restingHeartRate: 50, sex: .female).value == nil)
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax, restingHeartRate: 200, sex: .female).value == nil)
        #expect(TrainingLoad.banisterTRIMP(range: range, samples: samples, hrMax: hrMax, restingHeartRate: .nan, sex: .male).value == nil)
    }
}

// MARK: - 3. Overnight resting heart rate

@Suite("Adversarial: overnight resting heart rate")
struct AdvRestingHeartRateTests {
    let s = AX.t0 + 23 * AX.h
    var night: TimeRange { TimeRange(start: s, end: s + 8 * AX.h) }

    func estimate(_ samples: [HeartRateSample], window: TimeRange? = nil) -> MetricValue<Double> {
        RestingHeartRateEstimator.estimate(sleepWindow: window ?? night, samples: samples).restingHeartRate
    }

    @Test func estimateIsTheLowestFiveMinuteTimeWeightedMean() {
        let dip = s + 2 * AX.h
        let samples = AX.hrRun(s, count: 8 * 3_600) { k in
            let t = s + Int64(k) * 1_000
            return t >= dip && t < dip + 240_000 ? 40 : 60
        }
        let r = RestingHeartRateEstimator.estimate(sleepWindow: night, samples: samples)
        axCheck(r.restingHeartRate)
        #expect(r.restingHeartRate.value == 44)          // 4 min at 40 + 1 min at 60, not the 40-bpm minimum
        #expect(r.lowestWindow?.durationMillis == 300_000)
    }

    @Test func windowsSlideByWholeMinutesFromTheSleepStart() {
        // A 5-min dip starting 30 s after a minute boundary: the best 1-min-aligned window holds 4.5 min of it.
        let dip = s + 2 * AX.h + 30_000
        let samples = AX.hrRun(s, count: 8 * 3_600) { k in
            let t = s + Int64(k) * 1_000
            return t >= dip && t < dip + 300_000 ? 40 : 60
        }
        #expect(estimate(samples).value == 42)            // (270·40 + 30·60) / 300
    }

    @Test func aFiveMinuteWindowIsEligibleAtExactlyEightyPercentCoverage() {
        let dip = s + 2 * AX.h
        func samples(lowCovered: Int) -> [HeartRateSample] {
            var out = AX.hrRun(s, count: 7_200) { _ in 60 }                               // [s, dip)
            out += AX.hrRun(dip, count: lowCovered - 4) { _ in 45 }                      // covers `lowCovered` s
            out += AX.hrRun(dip + 300_000, count: 6 * 3_600 - 300) { _ in 60 }            // [dip + 5 min, end)
            return out
        }
        #expect(estimate(samples(lowCovered: 240)).value == 45)   // 240 of 300 s = 80 %: eligible
        #expect(estimate(samples(lowCovered: 239)).value == 48)   // 79.7 %: not eligible; next best (60·60 + 239·45)/299
    }

    @Test func longSleepWindowsNeedThreeHoursOfCoveredHeartRate() throws {
        let enough = AX.hrRun(s, count: 10_796) { _ in 55 }       // 10,795 s + a final 5-s span = 3 h
        #expect(estimate(enough).value == 55)
        let short = estimate(AX.hrRun(s, count: 10_795) { _ in 55 })   // 2 h 59 min 59 s
        axCheck(short)
        #expect(short.value == nil)
        guard case .insufficientData(let detail) = short.availability else {
            Issue.record("expected insufficientData, got \(short.availability)")
            return
        }
        #expect(detail.contains("3 h"), "states what is needed: \(detail)")
        #expect(detail.contains("2 h 59"), "states what is available: \(detail)")
    }

    @Test func shortSleepWindowsNeedSixtyPercentCoverageAndFiveHoursIsNotShort() {
        let four = TimeRange(start: s, end: s + 4 * AX.h)
        // 2.5 h of 4 h (62.5 %): enough for a short window although under 3 h.
        #expect(estimate(AX.hrRun(s, count: 8_996) { _ in 50 }, window: four).value == 50)
        // 59 % of 4 h: not enough.
        let low = estimate(AX.hrRun(s, count: 8_492) { _ in 50 }, window: four)
        #expect(low.value == nil)
        #expect(axKind(low.availability) == "insufficientData")
        // 4 h 59 min with exactly 60 % (10,764 s) covered: enough; 1 s less is not.
        let almostFive = TimeRange(start: s, end: s + 5 * AX.h - AX.m)
        #expect(estimate(AX.hrRun(s, count: 10_760) { _ in 50 }, window: almostFive).value == 50)
        #expect(estimate(AX.hrRun(s, count: 10_759) { _ in 50 }, window: almostFive).value == nil)
        // Exactly 5 h is not "shorter than 5 h": the 3-h rule applies.
        let five = TimeRange(start: s, end: s + 5 * AX.h)
        #expect(estimate(AX.hrRun(s, count: 10_796) { _ in 50 }, window: five).value == 50)
        #expect(estimate(AX.hrRun(s, count: 10_795) { _ in 50 }, window: five).value == nil)
    }

    @Test func valueIsRoundedToOneTenthOfABeat() {
        // Best window: 200 s at 50 + 100 s at 57 = 52.33 bpm; everything else is 70.
        let d = s + 3 * AX.h
        let samples = AX.hrRun(s, count: 8 * 3_600) { k in
            let t = s + Int64(k) * 1_000
            if t >= d && t < d + 200_000 { return 50 }
            if t >= d + 200_000 && t < d + 300_000 { return 57 }
            return 70
        }
        #expect(estimate(samples).value == 52.3)
    }

    @Test func overnightEstimateIsWithheldWithoutEnoughGoodData() {
        let full = AX.hrRun(s, count: 8 * 3_600) { _ in 55 }
        let cases: [(String, [HeartRateSample], TimeRange)] = [
            ("no samples", [], night),
            ("all flagged", AX.flag(full, .noSensorContact), night),
            ("all clock-unmapped", AX.flag(full, .clockUnmapped), night),
            // one sample every 10 s: 4 h covered (≥ 3 h) but no 5-min window reaches 80 %
            ("sparse", AX.hrRun(s, count: 8 * 360, step: 10_000) { _ in 55 }, night),
            ("window shorter than 5 min", full, TimeRange(start: s, end: s + 4 * AX.m)),
            ("empty window", full, TimeRange(start: s, end: s)),
            ("reversed window", full, TimeRange(start: s + AX.h, end: s)),
        ]
        for (name, samples, window) in cases {
            let r = estimate(samples, window: window)
            axCheck(r, name)
            #expect(r.value == nil, "\(name)")
        }
    }

    @Test func estimateLiesBetweenTheLowestAndHighestUsableSample() {
        var rng = AdvRNG(seed: 99)
        for _ in 0..<10 {
            var samples: [HeartRateSample] = []
            var bpm = 60
            var t = s
            while t < s + 6 * AX.h {
                bpm = min(90, max(45, bpm + Int.random(in: -2...2, using: &rng)))
                if Int.random(in: 0..<500, using: &rng) == 0 { t += Int64.random(in: 10_000...600_000, using: &rng) }
                samples.append(AX.hr(t, bpm))
                t += 1_000
            }
            let window = TimeRange(start: s, end: s + 6 * AX.h)
            let r = RestingHeartRateEstimator.estimate(sleepWindow: window, samples: samples)
            axCheck(r.restingHeartRate)
            let inside = samples.filter { window.contains($0.timestamp) }.map(\.bpm)
            if let v = r.restingHeartRate.value, let lo = inside.min(), let hi = inside.max() {
                #expect(v >= Double(lo) - 0.05 && v <= Double(hi) + 0.05)
                #expect(abs((v * 10).rounded() - v * 10) < 1e-6, "rounded to 0.1 bpm")
            }
            if let lw = r.lowestWindow {
                #expect(lw.durationMillis == 300_000 && lw.start >= window.start && lw.end <= window.end)
            }
        }
    }

    @Test func labelSaysPersonalOvernightEstimateNotClinical() throws {
        let l = RestingHeartRateEstimator.label.lowercased()
        #expect(l.contains("personal") && l.contains("overnight") && l.contains("not a clinical"))
        let spec = try #require(MetricCatalog.spec(for: "forma.rhr.overnight"))
        #expect((spec.limitations.joined(separator: " ") + spec.name).lowercased().contains("not a clinical"))
    }
}

// MARK: - 4. HRV (RMSSD)

@Suite("Adversarial: HRV RMSSD")
struct AdvHRVTests {
    let t0 = AX.t0
    let amps: [Double] = [10, 12, 14, 16, 18, 20, 22]

    func range(windows: Int) -> TimeRange { TimeRange(start: t0, end: t0 + Int64(windows) * 300_000) }

    @Test func handComputedCycleSeries() throws {
        let r = HRVAnalyzer.analyze(beats: AX.cycleWindows(start: t0, amplitudes: amps), range: range(windows: 7))
        axCheck(r.rmssd)
        axCheck(r.lnRMSSD)
        axCheck(r.rawRMSSD)
        #expect(r.totalWindows == 7 && r.validWindows == 7)
        #expect(r.segmentCount == 7)
        #expect(r.totalBeats == 7 * 289 && r.acceptedBeats == 7 * 289)
        #expect(r.artifacts.ruleA == 0 && r.artifacts.ruleB == 0 && r.artifacts.flagged == 0)
        for (k, a) in amps.enumerated() {
            #expect(r.windows[k].beats == 289)
            #expect(r.windows[k].successivePairs == 288)
            #expect(abs((r.windows[k].rmssd ?? -1) - a * 5.0.squareRoot()) < 0.051, "window \(k)")
        }
        let rmssd = try #require(r.rmssd.value)
        #expect(abs(rmssd - 16 * 5.0.squareRoot()) < 0.051)          // median window: 35.78 ms
        let ln = try #require(r.lnRMSSD.value)
        #expect(abs(ln - log(16 * 5.0.squareRoot())) < 0.0011)       // 3.577
        let raw = try #require(r.rawRMSSD.value)
        #expect(abs(raw - (5.0 * 272).squareRoot()) < 0.051)         // pooled sqrt(5 · mean a²) = 36.88 ms
        #expect(r.rmssd.coverage == 1)
        #expect(abs((r.acceptedFraction ?? 0) - 1) < 1e-12)
    }

    @Test func lnRMSSDIsTheLogOfThePeriodMedianNotTheMedianOfLogs() throws {
        let r = HRVAnalyzer.analyze(beats: AX.cycleWindows(start: t0, amplitudes: [10, 12, 14, 16, 18, 20]), range: range(windows: 6))
        let rmssd = try #require(r.rmssd.value)
        #expect(abs(rmssd - 15 * 5.0.squareRoot()) < 0.051)          // (14√5 + 16√5) / 2 = 33.54 ms
        let ln = try #require(r.lnRMSSD.value)
        #expect(abs(ln - log(15 * 5.0.squareRoot())) < 0.0011)       // 3.513 (the median of the logs would be 3.511)
    }

    @Test func ectopicBeatIsRejectedAndOnlyTheDiagnosticValueIsInflated() throws {
        let clean = AX.cycleWindows(start: t0, amplitudes: amps)
        var beats = clean
        // Window 0, beats 100 (1000 ms) and 101 (1030 ms): a premature 650-ms beat and its compensatory pause.
        beats[100].intervalMillis = 650
        beats[100].timestamp -= 350
        beats[101].intervalMillis = 1_380
        let r = HRVAnalyzer.analyze(beats: beats, range: range(windows: 7))
        let base = HRVAnalyzer.analyze(beats: clean, range: range(windows: 7))
        #expect(r.artifacts.ruleB == 2)
        #expect(r.artifacts.ruleA == 0)
        #expect(r.segmentCount == 7)                                  // an ectopic beat is not a dropout
        #expect(r.acceptedBeats == 7 * 289 - 2)
        #expect(r.windows[0].successivePairs == 285)                  // three pairs touch the two rejected beats
        #expect(r.windows[0].isValid)
        #expect(r.rmssd.value == base.rmssd.value)
        let raw = try #require(r.rawRMSSD.value)
        let baseRaw = try #require(base.rawRMSSD.value)
        #expect(raw > baseRaw + 4)
    }

    @Test func dropoutStartsANewSegmentResetsRuleBAndIsNeverDifferenced() throws {
        var beats = AX.cycleWindows(start: t0, amplitudes: amps)
        let w3 = 3 * 289
        // Drop beats 150…154 of window 3 (≈ 5 s of silence) and lower every later interval of that window by
        // 300 ms. A difference across the gap would be ≈ −300 ms; within each segment they are unchanged.
        for j in 155..<289 { beats[w3 + j].intervalMillis -= 300 }
        beats.removeSubrange((w3 + 150)..<(w3 + 155))
        let r = HRVAnalyzer.analyze(beats: beats, range: range(windows: 7))
        #expect(r.segmentCount == 8)
        #expect(r.artifacts.ruleB == 0, "rule-B references restart with the new segment")
        #expect(r.windows[3].beats == 284)
        #expect(r.windows[3].successivePairs == 282)
        let a = 16.0
        let cycle = [1_000, 1_000 + 3 * a, 1_000, 1_000 + a]
        let intervals = (0..<289).map { cycle[$0 % 4] - ($0 >= 155 ? 300 : 0) }
        var sumSquares = 0.0
        var pairs = 0
        for j in 0..<288 where !(149..<155).contains(j) {
            let diff = intervals[j + 1] - intervals[j]
            sumSquares += diff * diff
            pairs += 1
        }
        #expect(pairs == 282)
        let expected = (sumSquares / Double(pairs)).squareRoot()
        #expect(abs((r.windows[3].rmssd ?? -1) - expected) < 0.051)
        #expect(abs((r.rmssd.value ?? -1) - expected) < 0.051)        // window 3 is the median window
    }

    @Test func ruleABoundsAreInclusive() {
        func ruleA(_ intervals: [Double]) -> Int {
            HRVAnalyzer.analyze(beats: AX.beatsCumulative(firstAt: t0 + 3_000, intervals: intervals), range: range(windows: 1)).artifacts.ruleA
        }
        let slow = (0..<100).map { $0 % 2 == 0 ? 1_990.0 : 2_000.0 }
        #expect(ruleA(slow) == 0)
        var slowBad = slow
        slowBad[51] = 2_000.5
        #expect(ruleA(slowBad) == 1)
        let fast = (0..<500).map { $0 % 2 == 0 ? 310.0 : 300.0 }
        #expect(ruleA(fast) == 0)
        var fastBad = fast
        fastBad[251] = 299.5
        #expect(ruleA(fastBad) == 1)
    }

    @Test func nonFiniteAndAbsurdIntervalsAreRejectedAndNeverPoisonTheResult() throws {
        var beats = AX.cycleWindows(start: t0, amplitudes: amps)
        let bad: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, -1_000, 1e308, .leastNonzeroMagnitude, 299.999, 2_000.001]
        for (i, x) in bad.enumerated() { beats[600 + 37 * i].intervalMillis = x }
        let r = HRVAnalyzer.analyze(beats: beats, range: range(windows: 7))
        #expect(r.artifacts.ruleA == bad.count)
        #expect(r.artifacts.ruleB == 0)
        axCheck(r.rmssd)
        axCheck(r.lnRMSSD)
        axCheck(r.rawRMSSD)
        let v = try #require(r.rmssd.value)
        #expect(abs(v - 16 * 5.0.squareRoot()) < 1)
    }

    @Test func ruleBUsesTheMedianOfTheLastFiveAcceptedIncludingEvenCounts() {
        func ruleB(_ intervals: [Double]) -> Int {
            HRVAnalyzer.analyze(beats: AX.beatsCumulative(firstAt: t0 + 2_000, intervals: intervals), range: range(windows: 1)).artifacts.ruleB
        }
        let tail = Array(repeating: 1_050.0, count: 10)
        // Four references [1000, 1000, 1100, 1100]: median 1050, so ±210 ms is allowed.
        #expect(ruleB([1_000, 1_000, 1_100, 1_100, 1_260] + tail) == 0)
        #expect(ruleB([1_000, 1_000, 1_100, 1_100, 1_261] + tail) == 1)
        #expect(ruleB([1_000, 1_000, 1_100, 1_100, 840] + tail) == 0)
        #expect(ruleB([1_000, 1_000, 1_100, 1_100, 839] + tail) == 1)
        // The reference is the last five accepted beats (median 1200), not every accepted beat (median 1000).
        let drift = Array(repeating: 1_000.0, count: 5) + [1_200, 1_200, 1_200]
        let after = Array(repeating: 1_200.0, count: 10)
        #expect(ruleB(drift + [1_440] + after) == 0)
        #expect(ruleB(drift + [1_441] + after) == 1)
        // Fewer than three accepted references: no rule-B check at all.
        #expect(ruleB([1_000, 1_000, 1_900] + Array(repeating: 1_000.0, count: 10)) == 0)
    }

    @Test func ruleBReferencesRestartAfterASourceChangeOrDropout() {
        let a = AX.beatsCumulative(firstAt: t0 + 1_000, intervals: Array(repeating: 1_000, count: 20))
        let lastA = a.last?.timestamp ?? t0
        let b = AX.beatsCumulative(firstAt: lastA + 600, intervals: Array(repeating: 600, count: 20), source: .liveVendorStream)
        let r1 = HRVAnalyzer.analyze(beats: a + b, range: range(windows: 1))
        #expect(r1.segmentCount == 2)
        #expect(r1.artifacts.ruleB == 0)
        let c = AX.beatsCumulative(firstAt: lastA + 5_000, intervals: Array(repeating: 600, count: 20))
        let r2 = HRVAnalyzer.analyze(beats: a + c, range: range(windows: 1))
        #expect(r2.segmentCount == 2)
        #expect(r2.artifacts.ruleB == 0)
        // Every in-segment difference is 0; only a (forbidden) difference across the gap would be non-zero.
        #expect((r2.rawRMSSD.value ?? 0) == 0, "a difference was formed across the dropout")
    }

    @Test func windowValidityThresholdsAreInclusive() throws {
        func window(_ beats: [BeatInterval]) throws -> HRVWindow {
            try #require(HRVAnalyzer.analyze(beats: beats, range: range(windows: 1)).windows.first)
        }
        // (a) 80 % accepted: every 5th of 250 beats has an implausible value (timestamps keep their rhythm).
        var base = AX.beatsCumulative(firstAt: t0 + 1_000, intervals: (0..<250).map { $0 % 2 == 0 ? 990 : 1_010 })
        for j in stride(from: 4, to: 250, by: 5) { base[j].intervalMillis = 250 }
        let at80 = try window(base)
        #expect(at80.beats == 250 && at80.acceptedBeats == 200)
        #expect(at80.successivePairs == 150)
        #expect(at80.isValid)
        base[0].intervalMillis = 250
        #expect(try !window(base).isValid)
        // (b) accepted intervals summing to exactly 180 s.
        let s180 = AX.beatsCumulative(firstAt: t0 + 990, intervals: (0..<180).map { $0 % 2 == 0 ? 990 : 1_010 })
        let w180 = try window(s180)
        #expect(abs(w180.acceptedIntervalMillis - 180_000) < 1e-9)
        #expect(w180.isValid)
        #expect(try !window(Array(s180.dropLast())).isValid)
        // (c) exactly 100 successive pairs.
        let p100 = AX.beatsCumulative(firstAt: t0 + 1_790, intervals: (0..<101).map { $0 % 2 == 0 ? 1_790 : 1_810 })
        let w100 = try window(p100)
        #expect(w100.successivePairs == 100 && w100.isValid)
        let w99 = try window(Array(p100.dropLast()))
        #expect(w99.successivePairs == 99 && !w99.isValid)
        #expect(w99.rmssd == nil)
    }

    @Test func periodValueNeedsSixValidWindowsAndCoverageIsValidOverTotal() throws {
        func withoutWindows1And2(_ beats: [BeatInterval]) -> [BeatInterval] {
            beats.filter { !($0.timestamp >= t0 + 300_000 && $0.timestamp < t0 + 900_000) }
        }
        let seven = HRVAnalyzer.analyze(beats: withoutWindows1And2(AX.cycleWindows(start: t0, amplitudes: amps)), range: range(windows: 7))
        axCheck(seven.rmssd)
        #expect(seven.validWindows == 5 && seven.totalWindows == 7)
        #expect(seven.rmssd.value == nil)
        #expect(axKind(seven.rmssd.availability) == "insufficientData")
        #expect(abs((seven.rmssd.coverage ?? -1) - 5.0 / 7.0) < 1e-12)
        let eight = HRVAnalyzer.analyze(beats: withoutWindows1And2(AX.cycleWindows(start: t0, amplitudes: amps + [20])), range: range(windows: 8))
        #expect(eight.validWindows == 6)
        #expect(eight.rmssd.coverage == 0.75)
        let v = try #require(eight.rmssd.value)
        #expect(abs(v - 19 * 5.0.squareRoot()) < 0.051)               // median of {10, 16, 18, 20, 20, 22}·√5
    }

    @Test func noBeatIntervalsMeansNoHRV() {
        let unsupported = HRVAnalyzer.analyze(beats: nil, range: range(windows: 6))
        for m in [unsupported.rmssd, unsupported.lnRMSSD, unsupported.rawRMSSD] {
            axCheck(m)
            #expect(axKind(m.availability) == "unsupportedSensor")
        }
        let empty = HRVAnalyzer.analyze(beats: [], range: range(windows: 6))
        for m in [empty.rmssd, empty.lnRMSSD, empty.rawRMSSD] {
            axCheck(m)
            #expect(m.value == nil)
        }
        #expect(empty.acceptedFraction == nil)
        let allFlagged = HRVAnalyzer.analyze(beats: AX.cycleWindows(start: t0, amplitudes: amps).map { var b = $0; b.quality = .noSensorContact; return b },
                                             range: range(windows: 7))
        #expect(allFlagged.rmssd.value == nil)
        #expect(allFlagged.validWindows == 0)
    }

    @Test func rawRMSSDUsesEveryInSegmentPairWithoutRejection() throws {
        // 1000, 1000, 1000, 250 (rule A), 1000, 1000 → differences 0, 0, −750, +750, 0.
        let beats = AX.beatsCumulative(firstAt: t0 + 1_000, intervals: [1_000, 1_000, 1_000, 250, 1_000, 1_000])
        let r = HRVAnalyzer.analyze(beats: beats, range: range(windows: 1))
        #expect(r.artifacts.ruleA == 1)
        #expect(r.segmentCount == 1)
        #expect(r.rmssd.value == nil)                                  // far too little for the period value…
        let raw = try #require(r.rawRMSSD.value)                       // …but the diagnostic is still reported
        #expect(abs(raw - (2 * 562_500.0 / 5).squareRoot()) < 0.051)   // 474.3 ms
        #expect(r.rawRMSSD.specID != r.rmssd.specID)
        let rawSpec = try #require(MetricCatalog.spec(for: r.rawRMSSD.specID))
        #expect((rawSpec.name + " " + rawSpec.method + " " + rawSpec.limitations.joined(separator: " ")).lowercased().contains("diagnostic"))
    }

    /// Independent, spec-only reference for segmentation and artifact classification (no device flags).
    struct Reference {
        var segments = 0, ruleA = 0, ruleB = 0, accepted = 0
        init(beats: [BeatInterval], range: TimeRange) {
            let sorted = beats.filter { range.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
            var refs: [Double] = []
            for (i, b) in sorted.enumerated() {
                var newSegment = i == 0
                if i > 0 {
                    let p = sorted[i - 1]
                    let dt = Double(b.timestamp - p.timestamp)
                    if dt < 0 || dt > b.intervalMillis + 2_000 || b.source != p.source { newSegment = true }
                }
                if newSegment {
                    segments += 1
                    refs.removeAll()
                }
                let x = b.intervalMillis
                if !(300.0...2_000.0).contains(x) {
                    ruleA += 1
                    continue
                }
                if refs.count >= 3 {
                    let s = refs.sorted()
                    let med = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
                    if abs(x - med) > 0.2 * med {
                        ruleB += 1
                        continue
                    }
                }
                accepted += 1
                refs.append(x)
                if refs.count > 5 { refs.removeFirst() }
            }
        }
    }

    @Test func randomSeriesMatchTheSpecReferenceAndStayInternallyConsistent() {
        var rng = AdvRNG(seed: 2026)
        let window = range(windows: 8)
        for _ in 0..<12 {
            var beats: [BeatInterval] = []
            var t = t0 + Int64.random(in: 0..<5_000, using: &rng)
            var i = 0
            while true {
                var x = Double(Int.random(in: 900...1_100, using: &rng))
                let roll = Int.random(in: 0..<100, using: &rng)
                if roll < 3 { x = Double(Int.random(in: 100...3_000, using: &rng)) }       // artifact
                if roll == 3 { t += Int64.random(in: 3_000...20_000, using: &rng) }        // dropout
                t += Int64(x)
                guard t < window.end else { break }
                beats.append(AX.beat(t, x, source: roll == 4 ? .liveVendorStream : .deviceHistory, index: i))
                i += 1
            }
            let r = HRVAnalyzer.analyze(beats: beats, range: window)
            let ref = Reference(beats: beats, range: window)
            #expect(r.segmentCount == ref.segments)
            #expect(r.artifacts.ruleA == ref.ruleA)
            #expect(r.artifacts.ruleB == ref.ruleB)
            #expect(r.acceptedBeats == ref.accepted)
            #expect(r.artifacts.flagged == 0)
            #expect(HRVAnalyzer.analyze(beats: beats.shuffled(using: &rng), range: window) == r, "independent of input order")

            #expect(r.totalWindows == 8 && r.windows.count == 8)
            #expect(r.windows.reduce(0) { $0 + $1.beats } == r.totalBeats)
            #expect(r.windows.reduce(0) { $0 + $1.acceptedBeats } == r.acceptedBeats)
            #expect(r.artifacts.total == r.totalBeats - r.acceptedBeats)
            if r.totalBeats > 0 {
                #expect(abs((r.acceptedFraction ?? -1) - Double(r.acceptedBeats) / Double(r.totalBeats)) < 1e-12)
            }
            for (k, win) in r.windows.enumerated() {
                #expect(win.range == TimeRange(start: t0 + Int64(k) * 300_000, end: t0 + Int64(k + 1) * 300_000))
                #expect(win.successivePairs <= max(0, win.acceptedBeats - 1))
                #expect(win.isValid == (win.rmssd != nil))
                if win.isValid {
                    #expect(Double(win.acceptedBeats) >= 0.8 * Double(win.beats) - 1e-9)
                    #expect(win.acceptedIntervalMillis >= 180_000 - 1e-6)
                    #expect(win.successivePairs >= 100)
                }
            }
            let valid = r.windows.compactMap(\.rmssd)
            #expect(r.validWindows == valid.count)
            #expect(r.rmssd.coverage.map { abs($0 - Double(valid.count) / 8) < 1e-12 } ?? true)
            axCheck(r.rmssd)
            if let v = r.rmssd.value {
                #expect(valid.count >= 6)
                let sorted = valid.sorted()
                let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
                #expect(abs(v - median) <= 0.1 + 1e-9)
                #expect(abs((r.lnRMSSD.value ?? -1) - log(v)) < 0.003)
            } else {
                #expect(r.lnRMSSD.value == nil)
            }
        }
    }

    @Test func moreArtifactsOrFewerValidWindowsNeverRaiseConfidence() {
        let clean = AX.cycleWindows(start: t0, amplitudes: Array(repeating: 16, count: 9))
        let all = HRVAnalyzer.analyze(beats: clean, range: range(windows: 9))
        var dirty = clean
        for i in stride(from: 0, to: dirty.count, by: 8) { dirty[i].quality = .deviceMarkedInvalid }   // 12.5 % flagged
        let withArtifacts = HRVAnalyzer.analyze(beats: dirty, range: range(windows: 9))
        let sixOfNine = HRVAnalyzer.analyze(beats: clean.filter { $0.timestamp < t0 + 6 * 300_000 }, range: range(windows: 9))
        #expect(all.rmssd.value != nil && withArtifacts.rmssd.value != nil && sixOfNine.rmssd.value != nil)
        #expect(withArtifacts.rmssd.confidence <= all.rmssd.confidence)
        #expect(sixOfNine.rmssd.confidence <= all.rmssd.confidence)
        #expect(withArtifacts.lnRMSSD.confidence == withArtifacts.rmssd.confidence)
        #expect(abs((withArtifacts.acceptedFraction ?? 0) - Double(withArtifacts.acceptedBeats) / Double(withArtifacts.totalBeats)) < 1e-12)
    }

    @Test(.timeLimit(.minutes(2)))
    func aFullNightOfBeatsIsHandled() throws {
        var rng = AdvRNG(seed: 8)
        var intervals: [Double] = []
        for _ in 0..<28_000 { intervals.append(Double(Int.random(in: 950...1_050, using: &rng))) }
        let beats = AX.beatsCumulative(firstAt: t0 + 1_000, intervals: intervals)
        let r = HRVAnalyzer.analyze(beats: beats, range: TimeRange(start: t0, end: t0 + 8 * AX.h))
        axCheck(r.rmssd)
        #expect(r.validWindows >= 90)
        #expect(r.rmssd.value != nil)
    }
}

// MARK: - 5–6. Trends and baselines

@Suite("Adversarial: trends and baselines")
struct AdvTrendBaselineTests {
    let end = AX.day(2026, 3, 31)

    @Test(arguments: [(TrendPeriod.days7, 4), (.days30, 14), (.days90, 45)])
    func trendMinimumDaysAreInclusive(period: TrendPeriod, need: Int) {
        let days = AX.days(endingOn: end, count: period.days, calendar: AX.utc)
        var values: [LocalDay: Double?] = [:]
        for d in days.prefix(need) { values[d] = 10 }                // includes the period's first day
        values[AX.shift(end, 1)] = 1_000                               // the day after the end
        values[AX.shift(days[0], -1)] = 1_000                          // the day before the first day
        values[AX.shift(end, -period.days - 5)] = .some(nil)
        let ok = TrendAnalyzer.summary(of: values, period: period, endingOn: end, calendar: AX.utc)
        axCheck(ok.statistics)
        #expect(ok.daysWithData == need)
        #expect(ok.statistics.value?.daysWithData == need)
        #expect(ok.statistics.value?.mean == 10)
        #expect(ok.statistics.value?.maximum == 10)
        #expect(ok.firstDay == days.first)
        #expect(ok.lastDay == end)
        values[days[0]] = nil
        let short = TrendAnalyzer.summary(of: values, period: period, endingOn: end, calendar: AX.utc)
        axCheck(short.statistics)
        #expect(short.daysWithData == need - 1)
        #expect(short.statistics.value == nil)
        #expect(axKind(short.statistics.availability) == "insufficientData")
    }

    @Test func trendStatisticsHandComputed() throws {
        let d = AX.days(endingOn: end, count: 7, calendar: AX.utc)
        let values: [LocalDay: Double?] = [d[0]: 1, d[1]: 2, d[2]: nil, d[3]: 3, d[4]: 10, d[6]: 4]
        let s = try #require(TrendAnalyzer.summary(of: values, period: .days7, endingOn: end, calendar: AX.utc).statistics.value)
        #expect(s.daysWithData == 5)
        #expect(s.mean == 4)
        #expect(s.median == 3)
        #expect(s.minimum == 1)
        #expect(s.maximum == 10)
        let sd = try #require(s.standardDeviation)
        #expect(abs(sd - (50.0 / 4).squareRoot()) < 1e-9 || abs(sd - (50.0 / 5).squareRoot()) < 1e-9)
        let even: [LocalDay: Double?] = [d[0]: 1, d[1]: 2, d[2]: 3, d[3]: 10]
        #expect(TrendAnalyzer.summary(of: even, period: .days7, endingOn: end, calendar: AX.utc).statistics.value?.median == 2.5)
        let constant = Dictionary(uniqueKeysWithValues: d.map { ($0, Double?.some(7)) })
        let c = try #require(TrendAnalyzer.summary(of: constant, period: .days7, endingOn: end, calendar: AX.utc).statistics.value)
        #expect(c.standardDeviation == 0)
        #expect(TrendAnalyzer.summaries(of: constant, endingOn: end, calendar: AX.utc).map(\.period) == [.days7, .days30, .days90])
    }

    @Test func nonFiniteDailyValuesAreNotData() {
        let d = AX.days(endingOn: end, count: 7, calendar: AX.utc)
        let poisoned: [LocalDay: Double?] = [d[0]: 1, d[1]: 2, d[2]: 3, d[3]: .nan, d[4]: .infinity, d[5]: -.infinity]
        let r = TrendAnalyzer.summary(of: poisoned, period: .days7, endingOn: end, calendar: AX.utc)
        axCheck(r.statistics)
        #expect(r.daysWithData == 3)
        #expect(r.statistics.value == nil)
        var fourFinite = poisoned
        fourFinite[d[6]] = 6
        let ok = TrendAnalyzer.summary(of: fourFinite, period: .days7, endingOn: end, calendar: AX.utc)
        axCheck(ok.statistics)
        #expect(ok.statistics.value?.mean == 3)
        #expect(ok.statistics.value?.maximum == 6)
        let huge: [LocalDay: Double?] = [d[0]: 1.7e308, d[1]: 1.7e308, d[2]: 1.7e308, d[3]: 1.7e308, d[4]: -1.7e308]
        let h = TrendAnalyzer.summary(of: huge, period: .days7, endingOn: end, calendar: AX.utc)
        axCheck(h.statistics)
        if let s = h.statistics.value {
            #expect(s.mean.isFinite && s.median.isFinite && (s.standardDeviation?.isFinite ?? true))
        }
    }

    @Test func calendarDaysAreCountedOnceAcrossDSTAndSkippedDays() throws {
        let cases: [(String, LocalDay)] = [("America/New_York", AX.day(2026, 3, 14)), ("America/New_York", AX.day(2026, 11, 7)),
                                           ("America/Santiago", AX.day(2026, 9, 10)), ("Australia/Lord_Howe", AX.day(2026, 4, 8)),
                                           ("Asia/Beirut", AX.day(2026, 4, 1)), ("Pacific/Apia", AX.day(2012, 1, 3))]
        for (id, last) in cases {
            let cal = try AX.calendar(id)
            let days = AX.days(endingOn: last, count: 8, calendar: cal)          // the 7-day period plus the day before
            #expect(Set(days).count == 8, "\(id)")
            var values: [LocalDay: Double?] = [:]
            for (i, d) in days.enumerated() { values[d] = i == 0 ? 1_000 : 10 }
            let s = TrendAnalyzer.summary(of: values, period: .days7, endingOn: last, calendar: cal)
            #expect(s.daysWithData == 7, "\(id)")
            #expect(s.statistics.value?.mean == 10, "\(id)")
            let ninety = AX.days(endingOn: last, count: 91, calendar: cal)
            var nv: [LocalDay: Double?] = [:]
            for (i, d) in ninety.enumerated() { nv[d] = i == 0 ? 1_000 : 10 }
            #expect(TrendAnalyzer.summary(of: nv, period: .days90, endingOn: last, calendar: cal).daysWithData == 90, "\(id)")
        }
        // Samoa skipped 2011-12-30 entirely: a value is never counted twice.
        let apia = try AX.calendar("Pacific/Apia")
        let only31: [LocalDay: Double?] = [AX.day(2011, 12, 31): 5]
        #expect(TrendAnalyzer.summary(of: only31, period: .days7, endingOn: AX.day(2012, 1, 2), calendar: apia).daysWithData == 1)
        // A day that does not exist is not a valid end day, and never traps.
        let skipped = TrendAnalyzer.summary(of: only31, period: .days7, endingOn: AX.day(2011, 12, 30), calendar: apia)
        axCheck(skipped.statistics)
        for bad in [AX.day(2026, 2, 29), AX.day(2026, 4, 31), AX.day(0, 0, 0), AX.day(Int.max, 12, 31), AX.day(-4_000, 1, 1)] {
            let r = TrendAnalyzer.summary(of: only31, period: .days90, endingOn: bad, calendar: AX.utc)
            axCheck(r.statistics)
            #expect(r.statistics.value == nil)
            axCheck(TrendAnalyzer.recentVersusPrior(of: only31, endingOn: bad, calendar: AX.utc))
        }
    }

    @Test func recentVersusPriorWindowsAndMinimums() throws {
        let all = AX.days(endingOn: end, count: 36, calendar: AX.utc)  // all[0] = end − 35 (outside both windows)
        let prior = Array(all[1...28])
        let recent = Array(all[29...35])
        #expect(recent.last == end)
        var v: [LocalDay: Double?] = [:]
        for d in [recent[0], recent[2], recent[4], recent[6]] { v[d] = 60 }
        for d in [prior[0]] + Array(prior[1...12]) + [prior[27]] { v[d] = 50 }
        v[all[0]] = 1_000
        let ok = TrendAnalyzer.recentVersusPrior(of: v, endingOn: end, calendar: AX.utc)
        axCheck(ok)
        let c = try #require(ok.value)
        #expect(c.recentDays == 4 && c.priorDays == 14)
        #expect(c.recentMean == 60 && c.priorMean == 50)
        #expect(c.difference == 10)
        #expect(abs((c.percentDifference ?? 0) - 20) < 1e-9)
        var fewRecent = v
        fewRecent[recent[6]] = nil
        #expect(TrendAnalyzer.recentVersusPrior(of: fewRecent, endingOn: end, calendar: AX.utc).value == nil)
        var fewPrior = v
        fewPrior[prior[27]] = nil
        let fp = TrendAnalyzer.recentVersusPrior(of: fewPrior, endingOn: end, calendar: AX.utc)
        axCheck(fp)
        #expect(fp.value == nil)
        // A zero prior mean leaves the percentage undefined: nil, never 0 or infinite.
        var zero = v
        for d in prior where zero[d] != nil { zero[d] = 0 }
        let z = try #require(TrendAnalyzer.recentVersusPrior(of: zero, endingOn: end, calendar: AX.utc).value)
        #expect(z.percentDifference == nil)
        #expect(z.difference == 60)
    }

    @Test func trendOutputsAreDescriptiveOnly() throws {
        let phrases = ["because", "due to", "caused by", "as a result", "leads to", "led to", "you should", "recommend"]
        let d = AX.days(endingOn: end, count: 40, calendar: AX.utc)
        var rich: [LocalDay: Double?] = [:]
        for (i, day) in d.enumerated() { rich[day] = Double(50 + i % 7) }
        var texts: [String] = []
        let datasets: [[LocalDay: Double?]] = [rich, [:], [d[39]: 1]]
        for values in datasets {
            for s in TrendAnalyzer.summaries(of: values, endingOn: end, calendar: AX.utc, metricID: "forma.rhr.overnight") {
                texts += Array(s.statistics.inputs.values) + [s.statistics.availability.explanation]
            }
            let c = TrendAnalyzer.recentVersusPrior(of: values, endingOn: end, calendar: AX.utc)
            texts += Array(c.inputs.values) + [c.availability.explanation]
        }
        let spec = try #require(MetricCatalog.spec(for: "forma.trends"))
        texts += [spec.method, spec.windowing] + spec.qualityGates + spec.limitations
        for text in texts {
            for p in phrases { #expect(!text.lowercased().contains(p), "causal or advisory wording: \(text)") }
        }
    }

    // Baselines

    func previous(_ target: LocalDay, _ count: Int = 28, _ cal: Calendar = AX.utc) -> [LocalDay] {
        AX.days(endingOn: AX.shift(target, -1, cal), count: count, calendar: cal)
    }

    @Test func baselineMADExclusionHandExample() throws {
        let target = end
        var v: [LocalDay: Double?] = [:]
        let pattern: [Double] = Array(repeating: 50, count: 10) + Array(repeating: 51, count: 7) + Array(repeating: 52, count: 10) + [80]
        for (d, x) in zip(previous(target), pattern) { v[d] = x }
        v[target] = 1_000                       // the target day is never part of its own baseline
        v[AX.shift(target, -29)] = 1_000        // nor is the 29th day before it
        let b = BaselineCalculator.baseline(values: v, targetDay: target, calendar: AX.utc,
                                            parameters: BaselineParameters(windowDays: 28, minimumDays: 14))
        axCheck(b)
        let s = try #require(b.value)
        #expect(s.n == 27 && s.excluded == 1)
        #expect(abs(s.mean - 51) < 1e-12)
        #expect(s.median == 51)
        #expect(s.medianAbsoluteDeviation == 1)
        let sd = try #require(s.standardDeviation)
        #expect(abs(sd - (20.0 / 26).squareRoot()) < 1e-9 || abs(sd - (20.0 / 27).squareRoot()) < 1e-9)
    }

    @Test(arguments: [(4.4477, false), (4.4479, true), (-4.4477, false), (-4.4479, true)])
    func baselineMADCutoffIsStrict(offset: Double, excluded: Bool) throws {
        // Median 51, MAD 1 → limit 3 × 1.4826 × 1 = 4.4478.
        let target = end
        var v: [LocalDay: Double?] = [:]
        let pattern: [Double] = Array(repeating: 50, count: 10) + Array(repeating: 51, count: 7) + Array(repeating: 52, count: 10) + [51 + offset]
        for (d, x) in zip(previous(target), pattern) { v[d] = x }
        let s = try #require(BaselineCalculator.baseline(values: v, targetDay: target, calendar: AX.utc).value)
        #expect(s.median == 51 && s.medianAbsoluteDeviation == 1)
        #expect(s.excluded == (excluded ? 1 : 0))
        #expect(s.n == (excluded ? 27 : 28))
    }

    @Test func baselineWithZeroMADExcludesNothing() throws {
        var v: [LocalDay: Double?] = [:]
        for (i, d) in previous(end).enumerated() { v[d] = i == 13 ? 500 : 50 }
        let s = try #require(BaselineCalculator.baseline(values: v, targetDay: end, calendar: AX.utc).value)
        #expect(s.excluded == 0 && s.n == 28)
        #expect(abs(s.mean - (27 * 50 + 500) / 28.0) < 1e-12)
    }

    @Test func baselineCalibratingCountsRetainedValues() {
        let p = BaselineParameters(windowDays: 28, minimumDays: 14)
        func calibration(_ v: [LocalDay: Double?]) -> (Int, Int)? {
            let b = BaselineCalculator.baseline(values: v, targetDay: end, calendar: AX.utc, parameters: p)
            axCheck(b)
            if case let .calibrating(have, need, _) = b.availability { return (have, need) }
            return nil
        }
        let prev = previous(end)
        var ten: [LocalDay: Double?] = [:]
        for d in prev.suffix(10) { ten[d] = 50 }
        #expect(calibration(ten).map { $0 == (10, 14) } == true)
        // 14 values, one of them an outlier: 13 retained < 14.
        var withOutlier: [LocalDay: Double?] = [:]
        let pattern: [Double] = [49, 49, 49, 49, 50, 50, 50, 50, 50, 51, 51, 51, 51, 500]
        for (d, x) in zip(prev.suffix(14), pattern) { withOutlier[d] = x }
        #expect(calibration(withOutlier).map { $0 == (13, 14) } == true)
        // Only the target day and the day before the window: nothing eligible.
        #expect(calibration([end: 50, AX.shift(end, -29): 50]).map { $0 == (0, 14) } == true)
        // Both edges of the window count.
        #expect(calibration([prev[0]: 50, prev[27]: 50]).map { $0 == (2, 14) } == true)
    }

    @Test func baselineWindowCountsExactlyTheCalendarDays() throws {
        let cases: [(String, LocalDay)] = [("America/New_York", AX.day(2026, 3, 20)), ("America/New_York", AX.day(2026, 11, 15)),
                                           ("America/Santiago", AX.day(2026, 9, 20)), ("Pacific/Apia", AX.day(2012, 1, 15)),
                                           ("Australia/Lord_Howe", AX.day(2026, 4, 20))]
        for (id, target) in cases {
            let cal = try AX.calendar(id)
            let prev = previous(target, 29, cal)                             // the window plus one older day
            #expect(Set(prev).count == 29, "\(id)")
            var v: [LocalDay: Double?] = [target: 999]
            for (i, d) in prev.enumerated() { v[d] = i == 0 ? 999 : 7 }
            let b = BaselineCalculator.baseline(values: v, targetDay: target, calendar: cal,
                                                parameters: BaselineParameters(windowDays: 28, minimumDays: 14))
            #expect(b.value?.n == 28, "\(id)")
            #expect(b.value?.mean == 7, "\(id)")
        }
    }

    @Test func baselineWindowLengthIsConfigurable() {
        let p = BaselineParameters(windowDays: 7, minimumDays: 3)
        var v: [LocalDay: Double?] = [:]
        for k in 1...7 { v[AX.shift(end, -k)] = 10 }
        v[AX.shift(end, -8)] = 1_000        // just outside a 7-day window
        let b = BaselineCalculator.baseline(values: v, targetDay: end, calendar: AX.utc, parameters: p)
        axCheck(b)
        #expect(b.value?.n == 7)
        #expect(b.value?.mean == 10)
        #expect(b.coverage == 1)
    }

    @Test func robustStatisticsHostileValues() {
        #expect(BaselineCalculator.robustStatistics([]) == nil)
        #expect(BaselineCalculator.robustStatistics([.nan, .infinity, -.infinity]) == nil)
        let s = BaselineCalculator.robustStatistics([1, 2, 3, .nan])
        #expect(s?.n == 3)
        if let x = BaselineCalculator.robustStatistics([1.7e308, 1.7e308, -1.7e308, 1e308]) {
            #expect(x.mean.isFinite && (x.standardDeviation?.isFinite ?? true))
        }
        // One eligible value can never satisfy the minimum (or the parameters are nonsense): never a value.
        for p in [BaselineParameters(windowDays: 0), BaselineParameters(windowDays: -3), BaselineParameters(windowDays: 10_000),
                  BaselineParameters(minimumDays: 1_000), BaselineParameters(outlierMADMultiplier: .nan),
                  BaselineParameters(madScale: -1)] {
            let b = BaselineCalculator.baseline(values: [AX.shift(end, -1): 1], targetDay: end, calendar: AX.utc, parameters: p)
            axCheck(b)
            #expect(b.value == nil)
        }
    }
}

// MARK: - 7. Sleep candidates and confirmed-window summaries

@Suite("Adversarial: sleep")
struct AdvSleepTests {
    let morning = AX.day(2026, 1, 6)
    /// Noon 5 Jan → noon 6 Jan (UTC) and a 23:00–07:00 night inside it.
    let ws = AX.t0 + 12 * AX.h
    let we = AX.t0 + 36 * AX.h
    let ss = AX.t0 + 23 * AX.h
    let se = AX.t0 + 31 * AX.h

    func asleep(_ t: EpochMillis) -> Bool { t >= ss && t < se }
    /// Minute index since sleep onset (only meaningful while asleep).
    func minute(_ t: EpochMillis) -> Int64 { (t - ss) / AX.m }
    func night(_ activity: (EpochMillis) -> Double?) -> [MotionEpoch] { AX.motionMinutes(ws, we, activity) }
    var clear: [MotionEpoch] { night { asleep($0) ? 0.003 : 0.08 } }

    func detect(_ motion: [MotionEpoch]?, heartRate: [HeartRateSample]? = nil,
                parameters: SleepDetectorParameters = .default) -> MetricValue<SleepCandidate> {
        SleepDetector.detect(nightEndingOn: morning, calendar: AX.utc, motion: motion, heartRate: heartRate, parameters: parameters)
    }

    func heartRate(asleep a: Int, awake b: Int) -> [HeartRateSample] {
        AX.hrRun(ws, count: Int((we - ws) / 5_000), step: 5_000) { k in asleep(ws + Int64(k) * 5_000) ? a : b }
    }

    @Test func sleepIsNeverInferredFromHeartRateAlone() {
        let hr = heartRate(asleep: 50, awake: 80)
        let none = detect(nil, heartRate: hr)
        axCheck(none)
        #expect(none.availability == .unsupportedSensor(sensor: "motion (accelerometer)"))
        #expect(none.value == nil)
        let empty = detect([], heartRate: hr)
        axCheck(empty)
        #expect(empty.value == nil)
        // Epochs without accelerometer samples are missing data, not stillness.
        let zeros = night { _ in 0 }.map { var e = $0; e.sampleCount = 0; return e }
        #expect(detect(zeros, heartRate: hr).value == nil)
        let negativeCounts = night { _ in 0 }.map { var e = $0; e.sampleCount = -100; return e }
        #expect(detect(negativeCounts, heartRate: hr).value == nil)
        let summary = SleepSummary.fromConfirmedWindow(TimeRange(start: ss, end: se), motion: nil, heartRate: hr)
        #expect(summary.timeInBed.value == 8 * AX.h)
        #expect(summary.wakeDuration.value == nil)
        #expect(summary.sleepDurationEstimate.value == nil)
        #expect(summary.continuity.value == nil)
        #expect(summary.wakeBouts == nil)
        axCheck(summary.sleepDurationEstimate)
    }

    @Test func thresholdIsTwiceP10ClampedToTheConfiguredBounds() throws {
        let p = SleepDetectorParameters(thresholdLowerBound: 0.01, thresholdUpperBound: 0.04)
        // Night mostly at 0.012 (a third of the window) → θ = 2 × 0.012 = 0.024, inside the bounds.
        // The probe blocks are 5 min long, so they stay inside one merged candidate (merge gap 10 min).
        let mid = night { t in
            guard asleep(t) else { return 0.08 }
            switch minute(t) {
            case 60..<90: return 0.02      // below θ: quiet
            case 180..<185: return 0.03    // above θ: wake
            case 300..<305: return 0.024   // exactly θ: not quiet (quiet is strictly below θ)
            default: return 0.012
            }
        }
        let c = try #require(detect(mid, parameters: p).value)
        #expect(abs(c.activityThreshold - 0.024) < 1e-12)
        #expect(c.range == TimeRange(start: ss, end: se))
        #expect(c.wakeBouts == [TimeRange(start: ss + 180 * AX.m, end: ss + 185 * AX.m),
                                TimeRange(start: ss + 300 * AX.m, end: ss + 305 * AX.m)])
        #expect(c.sleepDurationEstimateMillis == 470 * AX.m)
        // Lower clamp: 2 × 0.003 = 0.006 → 0.01.
        let low = try #require(detect(clear, parameters: p).value)
        #expect(abs(low.activityThreshold - 0.01) < 1e-12)
        // Upper clamp: 2 × 0.05 = 0.1 → 0.04, and nothing at 0.05 is quiet.
        let high = detect(night { asleep($0) ? 0.05 : 0.08 }, parameters: p)
        axCheck(high)
        #expect(high.value == nil)
        // Defaults are documented in the parameters and need hardware calibration.
        let defaults = SleepDetectorParameters.default
        #expect(defaults.thresholdLowerBound < defaults.thresholdUpperBound)
        let spec = try #require(MetricCatalog.spec(for: "forma.sleep.candidate"))
        #expect((spec.limitations + [spec.method]).joined(separator: " ").lowercased().contains("calibrat"))
    }

    @Test(arguments: [(10, true), (11, false)])
    func quietRunsMergeAcrossAtMostTenMinutes(gap: Int, merged: Bool) throws {
        let g = Int64(gap)
        let motion = night { t in
            guard t >= ss else { return 0.08 }
            let k = minute(t)
            if k < 120 { return 0.003 }
            if k < 120 + g { return 0.08 }
            if k < 240 + g { return 0.003 }
            return 0.08
        }
        let r = detect(motion)
        axCheck(r)
        if merged {
            let c = try #require(r.value)
            #expect(c.range == TimeRange(start: ss, end: ss + (240 + g) * AX.m))
            #expect(c.wakeBouts == [TimeRange(start: ss + 120 * AX.m, end: ss + (120 + g) * AX.m)])
            #expect(c.wakeAfterSleepOnsetMillis == g * AX.m)
            #expect(c.sleepDurationEstimateMillis == 240 * AX.m)
            #expect(abs(c.continuity - (1 - Double(g) / Double(240 + g))) < 1e-12)
        } else {
            #expect(r.value == nil)                    // two 2-h runs, neither reaches 3 h
        }
    }

    @Test(arguments: [(180, true), (179, false)])
    func mainCandidateNeedsAtLeastThreeHours(minutes: Int, found: Bool) {
        let motion = night { t in t >= ss && minute(t) < Int64(minutes) ? 0.003 : 0.08 }
        let r = detect(motion)
        axCheck(r)
        #expect((r.value != nil) == found)
        if found { #expect(r.value?.range.durationMillis == 3 * AX.h) }
    }

    @Test func wakeBoutsNeedTwoClassifiedNonQuietEpochs() throws {
        // Raw H·L·H·L·H leaves one classified active epoch (not a bout); raw H·H·L·H leaves two (a bout).
        let highs: Set<Int64> = [120, 122, 124, 240, 241, 243]
        let motion = night { t in asleep(t) ? (highs.contains(minute(t)) ? 0.08 : 0.003) : 0.08 }
        let c = try #require(detect(motion).value)
        #expect(c.range == TimeRange(start: ss, end: se))
        #expect(c.wakeBouts == [TimeRange(start: ss + 241 * AX.m, end: ss + 243 * AX.m)])
        #expect(c.wakeAfterSleepOnsetMillis == 2 * AX.m)
        #expect(c.sleepDurationEstimateMillis == 478 * AX.m)
        #expect(abs(c.continuity - (1 - 2.0 / 480)) < 1e-12)
    }

    // IMPLEMENTATION BUG (spec deviation): the spec defines wake bouts as the NON-QUIET runs of ≥ 2 epochs inside
    // the candidate and the sleep estimate as length − wake bouts. Minutes with no accelerometer data are not
    // quiet, but the implementation only counts *active* runs as wake, so unobserved minutes are reported as
    // sleep (fabricated sleep time).
    @Test("IMPLEMENTATION BUG: unobserved minutes inside a candidate must not be counted as sleep")
    func missingMotionInsideACandidateIsNotCountedAsSleep() throws {
        let motion = night { t in asleep(t) ? ((240..<246).contains(minute(t)) ? nil : 0.003) : 0.08 }
        let c = try #require(detect(motion).value)
        #expect(c.range == TimeRange(start: ss, end: se))
        #expect(c.sleepDurationEstimateMillis <= 8 * AX.h - 6 * AX.m,
                "6 minutes without motion data were reported as sleep (estimate \(c.sleepDurationEstimateMillis) ms)")
    }

    // IMPLEMENTATION BUG (same root cause, confirmed-window path).
    @Test("IMPLEMENTATION BUG: unobserved minutes inside a confirmed window must not be counted as sleep")
    func missingMotionInsideAConfirmedWindowIsNotCountedAsSleep() throws {
        let motion = AX.motionMinutes(ss, se) { t in (240..<246).contains(minute(t)) ? nil : 0.003 }
        let s = SleepSummary.fromConfirmedWindow(TimeRange(start: ss, end: se), motion: motion)
        let sleep = try #require(s.sleepDurationEstimate.value)
        #expect(sleep <= 8 * AX.h - 6 * AX.m, "6 minutes without motion data were reported as sleep (estimate \(sleep) ms)")
    }

    @Test func lowMotionCoverageMakesTheCandidateLowQuality() {
        // Day: every other minute missing; night: 12 min of data then 8 min missing → under 70 % everywhere.
        func pattern(_ t: EpochMillis) -> Double? {
            if asleep(t) { return minute(t) % 20 < 12 ? 0.003 : nil }
            return ((t - ws) / AX.m) % 2 == 0 ? 0.08 : nil
        }
        let absent = night(pattern)
        let r = detect(absent)
        axCheck(r)
        #expect(r.value == nil)
        #expect(axKind(r.availability) == "lowQuality")
        // Same pattern, written as epochs that carry no samples instead of absent epochs.
        let zeroCount = stride(from: ws, to: we, by: Int(AX.m)).map { t in
            pattern(t).map { AX.motion(t, $0) } ?? AX.motion(t, 0, samples: 0)
        }
        let z = detect(zeroCount)
        #expect(z.value == nil)
        #expect(axKind(z.availability) == "lowQuality")
    }

    @Test func motionCoverageOfExactlySeventyPercentIsEnough() throws {
        // 480 candidate epochs, 336 with data (70 %): D×4, then (M×3, D×7) × 47, then M×3, D×3.
        func hasData(_ k: Int64) -> Bool {
            if k < 4 { return true }
            if k >= 474 { return k >= 477 }
            return (k - 4) % 10 >= 3
        }
        #expect((0..<480).filter(hasData).count == 336)
        let motion = night { t in asleep(t) ? (hasData(minute(t)) ? 0.003 : nil) : 0.08 }
        let r = detect(motion)
        axCheck(r)
        let c = try #require(r.value, "exactly 70 % motion coverage must not be low quality: \(r.availability)")
        #expect(c.range == TimeRange(start: ss, end: se))
        #expect(abs(c.coverage - 0.7) < 1e-12)
        // The confirmed-window path applies the same inclusive 70 % gate.
        let summary = SleepSummary.fromConfirmedWindow(TimeRange(start: ss, end: se),
                                                       motion: AX.motionMinutes(ss, se) { t in hasData(minute(t)) ? 0.003 : nil })
        #expect(summary.sleepDurationEstimate.value != nil, "\(summary.sleepDurationEstimate.availability)")
        #expect(summary.motionCoverage.map { abs($0 - 0.7) < 1e-12 } == true)
    }

    @Test func heartRateCoveringExactlyHalfTheCandidateCounts() throws {
        let base = try #require(detect(clear).value)
        // HR every 5 s for the first 4 h of the 8-h candidate (exactly 50 %) and for the whole day around it.
        let hr = heartRate(asleep: 52, awake: 75).filter { !asleep($0.timestamp) || $0.timestamp < ss + 4 * AX.h }
        let c = try #require(detect(clear, heartRate: hr).value)
        #expect(c.confidence > base.confidence, "support: \(c.heartRateSupport)")
    }

    @Test func heartRateCanOnlyAdjustConfidenceNeverCreateSleep() throws {
        let base = try #require(detect(clear).value)
        #expect(base.confidence >= 0 && base.confidence <= 1)
        let supported = try #require(detect(clear, heartRate: heartRate(asleep: 52, awake: 75)).value)
        #expect(supported.confidence > base.confidence)
        #expect(supported.range == base.range)
        #expect(supported.sleepDurationEstimateMillis == base.sleepDurationEstimateMillis)
        #expect(supported.confidence <= 1)
        // Heart rate covering under half of the candidate is ignored.
        let sparse = heartRate(asleep: 52, awake: 75).filter { !asleep($0.timestamp) || $0.timestamp < ss + 3 * AX.h }
        let fromSparse = try #require(detect(clear, heartRate: sparse).value)
        #expect(fromSparse.confidence == base.confidence)
        // A higher heart rate inside the candidate never raises confidence.
        let contrary = try #require(detect(clear, heartRate: heartRate(asleep: 80, awake: 70)).value)
        #expect(contrary.confidence <= base.confidence)
        #expect(contrary.confidence >= 0)
        // Flagged heart rate is not support.
        let flagged = try #require(detect(clear, heartRate: AX.flag(heartRate(asleep: 52, awake: 75), .noSensorContact)).value)
        #expect(flagged.confidence == base.confidence)
    }

    // SPEC DEVIATION (minor): the spec's only condition for heart-rate support is usable HR coverage ≥ 50 % inside
    // the candidate plus a lower mean than the window's out-of-candidate median. The implementation additionally
    // requires ≥ 30 min of heart rate outside the candidate, so a fully covered night with 20 min of evening HR gets
    // no confidence boost.
    @Test("SPEC DEVIATION: heart-rate support needs only 50 % coverage inside the candidate")
    func heartRateSupportNeedsOnlyHalfTheCandidateCovered() throws {
        let base = try #require(detect(clear).value)
        let hr = AX.hrRun(ss - 20 * AX.m, count: 240, step: 5_000) { _ in 75 } + AX.hrRun(ss, count: 8 * 720, step: 5_000) { _ in 52 }
        let withHR = try #require(detect(clear, heartRate: hr).value)
        #expect(withHR.confidence > base.confidence, "support: \(withHR.heartRateSupport)")
    }

    @Test func noonToNoonWindowFollowsDST() throws {
        let ny = try AX.calendar("America/New_York")
        let spring = try #require(SleepDetector.window(nightEndingOn: AX.day(2026, 3, 8), calendar: ny))
        #expect(spring.durationMillis == 23 * AX.h)
        #expect(spring.start == (try AX.epoch(ny, 2026, 3, 7, 12)))
        let fall = try #require(SleepDetector.window(nightEndingOn: AX.day(2026, 11, 1), calendar: ny))
        #expect(fall.durationMillis == 25 * AX.h)
        #expect(SleepDetector.window(nightEndingOn: AX.day(2026, 3, 11), calendar: ny)?.durationMillis == 24 * AX.h)
        // A clear 23:00–07:00 local night on the spring-forward night lasts 7 h.
        let onset = try AX.epoch(ny, 2026, 3, 7, 23)
        let wake = try AX.epoch(ny, 2026, 3, 8, 7)
        #expect(wake - onset == 7 * AX.h)
        let motion = AX.motionMinutes(spring.start, spring.end) { t in t >= onset && t < wake ? 0.003 : 0.08 }
        let r = SleepDetector.detect(nightEndingOn: AX.day(2026, 3, 8), calendar: ny, motion: motion)
        let c = try #require(r.value)
        #expect(r.window == spring)
        #expect(c.range == TimeRange(start: onset, end: wake))
        #expect(c.sleepDurationEstimateMillis == 7 * AX.h)
        // Fall-back night: 23:00 EDT → 07:00 EST spans the repeated hour and lasts 9 h of real time.
        let fallOnset = try AX.epoch(ny, 2026, 10, 31, 23)
        let fallWake = try AX.epoch(ny, 2026, 11, 1, 7)
        #expect(fallWake - fallOnset == 9 * AX.h)
        let fallMotion = AX.motionMinutes(fall.start, fall.end) { t in t >= fallOnset && t < fallWake ? 0.003 : 0.08 }
        let fc = try #require(SleepDetector.detect(nightEndingOn: AX.day(2026, 11, 1), calendar: ny, motion: fallMotion).value)
        #expect(fc.range == TimeRange(start: fallOnset, end: fallWake))
        #expect(fc.sleepDurationEstimateMillis == 9 * AX.h)
        let fs = SleepSummary.fromConfirmedWindow(TimeRange(start: fallOnset, end: fallWake), motion: fallMotion)
        #expect(fs.timeInBed.value == 9 * AX.h)
        // An invalid day never traps.
        axCheck(SleepDetector.detect(nightEndingOn: AX.day(2026, 2, 30), calendar: ny, motion: motion))
        axCheck(SleepDetector.detect(nightEndingOn: AX.day(Int.max, 1, 1), calendar: ny, motion: motion))
    }

    @Test func thirtySecondMotionEpochsGiveTheSameCandidate() throws {
        let fine = stride(from: ws, to: we, by: 30_000).map { t in AX.motion(t, asleep(t) ? 0.003 : 0.08, samples: 50, epoch: 30_000) }
        let coarse = try #require(detect(clear).value)
        let fromFine = try #require(detect(fine).value)
        #expect(fromFine.range == coarse.range)
        #expect(fromFine.sleepDurationEstimateMillis == coarse.sleepDurationEstimateMillis)
        // Order of the motion epochs does not matter.
        var rng = AdvRNG(seed: 5)
        #expect(detect(clear.shuffled(using: &rng)) == detect(clear))
    }

    @Test func hostileMotionValuesNeverTrapOrCreateSleep() {
        var hostile = clear
        for i in stride(from: 0, to: hostile.count, by: 7) {
            switch i % 5 {
            case 0: hostile[i].activity = .nan
            case 1: hostile[i].activity = .infinity
            case 2: hostile[i].activity = -1
            case 3: hostile[i].epochMillis = .max
            default: hostile[i].sampleCount = .max
            }
        }
        hostile.append(AX.motion(.max, 0.001))
        hostile.append(AX.motion(.min, 0.001))
        hostile.append(AX.motion(ws, 1e308))
        hostile.append(MotionEpoch(deviceID: "x", timestamp: ss, epochMillis: .min, activity: 0, sampleCount: 1, source: .demo))
        let r = detect(hostile)
        axCheck(r)
        if let c = r.value {
            #expect(c.confidence >= 0 && c.confidence <= 1)
            #expect(c.range.durationMillis >= 3 * AX.h)
        }
        let s = SleepSummary.fromConfirmedWindow(TimeRange(start: ss, end: se), motion: hostile)
        axCheck(s.timeInBed)
        axCheck(s.continuity)
        axCheck(s.sleepDurationEstimate)
    }

    @Test func candidateInvariantsOnRandomNights() {
        var rng = AdvRNG(seed: 314)
        for _ in 0..<15 {
            let onset = ws + Int64.random(in: 540...780, using: &rng) * AX.m           // 21:00 … 01:00
            let length = Int64.random(in: 120...600, using: &rng) * AX.m
            var bouts: [ClosedRange<Int64>] = []
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                let a = onset + Int64.random(in: 0...(length / AX.m), using: &rng) * AX.m
                bouts.append(a...(a + Int64.random(in: 1...25, using: &rng) * AX.m))
            }
            let motion = night { t in
                if Int.random(in: 0..<40, using: &rng) == 0 { return nil }
                let inSleep = t >= onset && t < onset + length && !bouts.contains { $0.contains(t) }
                return inSleep ? Double.random(in: 0.0...0.006, using: &rng) : Double.random(in: 0.05...0.3, using: &rng)
            }
            let r = detect(motion, heartRate: Bool.random(using: &rng) ? heartRate(asleep: 55, awake: 70) : nil)
            axCheck(r)
            guard let c = r.value, let window = r.window else { continue }
            #expect(c.range.durationMillis >= 3 * AX.h)
            #expect(window.start <= c.range.start && c.range.end <= window.end)
            var waso: Int64 = 0
            var previousEnd = c.range.start
            for b in c.wakeBouts {
                #expect(b.start >= previousEnd && b.end <= c.range.end)
                #expect(b.durationMillis >= 2 * AX.m)
                waso += b.durationMillis
                previousEnd = b.end
            }
            #expect(c.wakeAfterSleepOnsetMillis == waso)
            #expect(c.sleepDurationEstimateMillis == c.range.durationMillis - waso)
            #expect(abs(c.continuity - (1 - Double(waso) / Double(c.range.durationMillis))) < 1e-9)
            #expect(c.confidence >= 0 && c.confidence <= 1)
            #expect(c.coverage >= 0.7 - 1e-9 && c.coverage <= 1)
        }
    }

    @Test func confirmedWindowSummary() throws {
        let window = TimeRange(start: ss, end: se + 30_000)                 // 8 h 30 s
        let tib = 8 * AX.h + 30_000
        let none = SleepSummary.fromConfirmedWindow(window, motion: nil)
        #expect(none.timeInBed.value == tib)
        #expect(none.wakeDuration.value == nil && none.sleepDurationEstimate.value == nil && none.continuity.value == nil)
        let still = SleepSummary.fromConfirmedWindow(window, motion: AX.motionMinutes(ss, se + AX.m) { _ in 0.003 })
        #expect(still.timeInBed.value == tib)
        #expect(still.wakeDuration.value == 0)
        #expect(still.sleepDurationEstimate.value == tib)
        #expect(still.continuity.value == 1)
        let woke = SleepSummary.fromConfirmedWindow(window, motion: AX.motionMinutes(ss, se + AX.m) { t in
            (100..<130).contains(minute(t)) ? 0.08 : 0.003
        })
        #expect(woke.wakeDuration.value == 30 * AX.m)
        #expect(woke.sleepDurationEstimate.value == tib - 30 * AX.m)
        #expect(abs((woke.continuity.value ?? 0) - (1 - 1_800_000.0 / Double(tib))) < 1e-12)
        #expect(woke.wakeBouts == [TimeRange(start: ss + 100 * AX.m, end: ss + 130 * AX.m)])
        for bad in [TimeRange(start: ss, end: ss), TimeRange(start: .min, end: .max), TimeRange(start: se, end: ss)] {
            let s = SleepSummary.fromConfirmedWindow(bad, motion: [])
            axCheck(s.timeInBed)
            #expect(s.timeInBed.value.map { $0 > 0 } ?? true, "time in bed is never 0 or negative")
        }
    }

    @Test func noSleepStagesAnywhere() throws {
        let words = ["rem sleep", " rem ", "deep sleep", "light sleep", "slow-wave", "stage n"]
        let candidate = detect(clear, heartRate: heartRate(asleep: 52, awake: 75))
        let summary = SleepSummary.fromConfirmedWindow(TimeRange(start: ss, end: se), motion: clear, heartRate: heartRate(asleep: 52, awake: 75))
        let texts = Array(candidate.inputs.values) + Array(summary.continuity.inputs.values) + Array(summary.timeInBed.inputs.values)
        for t in texts {
            for w in words { #expect(!t.lowercased().contains(w), "\(t)") }
        }
        for id in ["forma.sleep.candidate", "forma.sleep.summary"] {
            let spec = try #require(MetricCatalog.spec(for: id))
            #expect(spec.limitations.joined(separator: " ").lowercased().contains("no sleep stages"), "\(id)")
        }
    }
}

// MARK: - 9. Readiness (experimental)

@Suite("Adversarial: readiness")
struct AdvReadinessTests {
    let target = AX.day(2026, 3, 31)

    /// Values for the nights before `target`, oldest first, plus the target night's own value.
    func nights(_ values: [Double], target t: Double?) -> [LocalDay: Double?] {
        var out: [LocalDay: Double?] = [:]
        let days = AX.days(endingOn: AX.shift(target, -1), count: values.count, calendar: AX.utc)
        for (d, v) in zip(days, values) { out[d] = v }
        if let t { out[target] = t }
        return out
    }

    func alternating(_ a: Double, _ b: Double, _ n: Int = 28) -> [Double] { (0..<n).map { $0 % 2 == 0 ? a : b } }

    func compute(hrv: [LocalDay: Double?], rhr: [LocalDay: Double?] = [:], sleep: [LocalDay: Double?] = [:]) -> ReadinessResult {
        ReadinessCalculator.compute(day: target, calendar: AX.utc, lnRMSSD: hrv, restingHeartRate: rhr, sleepDurationMinutes: sleep)
    }

    @Test func compositeHandComputed() throws {
        let r = compute(hrv: nights(alternating(4.00, 4.02), target: 4.11),
                        rhr: nights(alternating(50, 51), target: 52.5),
                        sleep: nights(alternating(420, 440), target: 490))
        axCheck(r.composite)
        let v = try #require(r.composite.value)
        #expect(abs(v - 0.8) < 0.0051)          // (0.5·2 + 0.3·(−2) + 0.2·2) / 1.0
        #expect(r.band == .withinUsual)
        #expect(r.weights == ReadinessWeights(hrv: 0.5, restingHeartRate: 0.3, sleepDuration: 0.2))
        #expect(MetricCatalog.spec(for: r.composite.specID)?.status == .experimental)
        let h = try #require(r.component(.hrv))
        #expect(h.value == 4.11)
        #expect(abs((h.z ?? 0) - 2) < 0.0051)
        #expect(h.weight == 0.5 && h.isIncluded)
        #expect(abs((h.baseline.value?.mean ?? 0) - 4.01) < 1e-9)
        #expect(h.baseline.value?.n == 28)
        #expect(h.standardDeviationUsed == 0.05)       // the baseline SD (≈ 0.01) is below the floor
        #expect(h.calibrationHave == 28 && h.calibrationNeed == 14)
        let rh = try #require(r.component(.restingHeartRate))
        #expect(abs((rh.z ?? 0) + 2) < 0.0051)         // higher resting HR than usual → negative z
        #expect(rh.signInverted)
        #expect(rh.standardDeviationUsed == 1.0)
        #expect(rh.calibrationNeed == 14)
        let sl = try #require(r.component(.sleepDuration))
        #expect(abs((sl.z ?? 0) - 2) < 0.0051)
        #expect(sl.standardDeviationUsed == 30)
        #expect(sl.calibrationNeed == 7)
    }

    @Test func sdFloorsPreventDivisionByAZeroSpread() throws {
        let r = compute(hrv: nights(Array(repeating: 4.0, count: 28), target: 4.1),
                        rhr: nights(Array(repeating: 50, count: 28), target: 49),
                        sleep: nights(Array(repeating: 420, count: 28), target: 390))
        axCheck(r.composite)
        let v = try #require(r.composite.value)
        #expect(abs(v - 1.1) < 0.0051)          // (0.5·2 + 0.3·1 + 0.2·(−1)) / 1.0
        #expect(r.band == .aboveUsual)
        #expect(r.components.allSatisfy { ($0.z ?? .nan).isFinite })
    }

    @Test func aBaselineSpreadAboveTheFloorIsUsed() throws {
        let r = compute(hrv: nights(alternating(3.8, 4.2), target: 4.4))
        let v = try #require(r.composite.value)
        let sampleSD = (28 * 0.04 / 27).squareRoot()
        #expect(abs(v - 2.0) < 0.0051 || abs(v - 0.4 / sampleSD) < 0.0051)
        #expect((r.component(.hrv)?.standardDeviationUsed ?? 0) > 0.05)
        #expect(r.component(.restingHeartRate)?.isIncluded == false)
        #expect(r.component(.sleepDuration)?.isIncluded == false)
    }

    @Test func compositeRequiresTheHRVComponent() throws {
        let rhr = nights(alternating(50, 51), target: 49)
        let sleep = nights(alternating(420, 440), target: 470)
        let missing = compute(hrv: nights(alternating(4.0, 4.02), target: nil), rhr: rhr, sleep: sleep)
        axCheck(missing.composite)
        #expect(missing.composite.value == nil)
        #expect(missing.band == nil)
        let calibrating = compute(hrv: nights(alternating(4.0, 4.02, 13), target: 4.1), rhr: rhr, sleep: sleep)
        axCheck(calibrating.composite)
        #expect(calibrating.composite.value == nil)
        #expect(calibrating.band == nil)
        #expect(calibrating.component(.hrv)?.calibrationHave == 13)
        #expect(calibrating.component(.hrv)?.calibrationNeed == 14)
        if case let .calibrating(have, need, _) = calibrating.composite.availability {
            #expect(have == 13 && need == 14)
        }
        let nanTarget = compute(hrv: nights(alternating(4.0, 4.02), target: .nan), rhr: rhr, sleep: sleep)
        #expect(nanTarget.composite.value == nil)
        let ready = compute(hrv: nights(alternating(4.0, 4.02, 14), target: 4.1), rhr: rhr, sleep: sleep)
        #expect(ready.composite.value != nil)
    }

    @Test func componentsCalibrateIndependently() throws {
        let hrv = nights(Array(repeating: 4.0, count: 28), target: 4.1)               // z = +2
        let rhr13 = nights(Array(repeating: 50, count: 13), target: 49)
        let sleep7 = nights(Array(repeating: 420, count: 7), target: 390)             // z = −1
        let r = compute(hrv: hrv, rhr: rhr13, sleep: sleep7)
        let v = try #require(r.composite.value)
        #expect(abs(v - 0.8 / 0.7) < 0.0051)                                           // (0.5·2 + 0.2·(−1)) / 0.7
        #expect(r.band == .aboveUsual)
        let rh = try #require(r.component(.restingHeartRate))
        #expect(!rh.isIncluded && rh.z == nil)
        #expect(rh.calibrationHave == 13 && rh.calibrationNeed == 14)
        let sleep6 = nights(Array(repeating: 420, count: 6), target: 390)
        let r6 = compute(hrv: hrv, rhr: rhr13, sleep: sleep6)
        #expect(abs((r6.composite.value ?? 0) - 2) < 0.0051)                          // HRV only
        #expect(r6.component(.sleepDuration)?.isIncluded == false)
        #expect(r6.component(.sleepDuration)?.calibrationHave == 6)
    }

    @Test func bandThresholdsAreInclusiveOfPlusMinusOne() {
        #expect(ReadinessCalculator.band(for: -1.0) == .withinUsual)
        #expect(ReadinessCalculator.band(for: -1.000001) == .belowUsual)
        #expect(ReadinessCalculator.band(for: 1.0) == .withinUsual)
        #expect(ReadinessCalculator.band(for: 1.000001) == .aboveUsual)
        #expect(ReadinessCalculator.band(for: 0) == .withinUsual)
        #expect(ReadinessCalculator.band(for: -.infinity) == .belowUsual)
        #expect(ReadinessCalculator.band(for: .infinity) == .aboveUsual)
        let base = Array(repeating: 4.0, count: 28)
        let cases: [(Double, ReadinessBand)] = [(3.95, .withinUsual), (3.9495, .belowUsual), (4.05, .withinUsual), (4.0505, .aboveUsual)]
        for (t, band) in cases {
            let r = compute(hrv: nights(base, target: t))
            #expect(r.band == band, "target \(t) → \(String(describing: r.composite.value))")
        }
        #expect(ReadinessBand.belowUsual.label == "below usual")
        #expect(ReadinessBand.withinUsual.label == "within usual")
        #expect(ReadinessBand.aboveUsual.label == "above usual")
    }

    @Test func customWeightsAreAppliedAndExposed() throws {
        let weights = ReadinessWeights(hrv: 1, restingHeartRate: 1, sleepDuration: 1)
        let r = ReadinessCalculator.compute(day: target, calendar: AX.utc,
                                            lnRMSSD: nights(Array(repeating: 4.0, count: 28), target: 4.1),          // z = +2
                                            restingHeartRate: nights(Array(repeating: 50, count: 28), target: 49),  // z = +1
                                            sleepDurationMinutes: nights(Array(repeating: 420, count: 28), target: 390), // z = −1
                                            parameters: ReadinessParameters(weights: weights))
        let v = try #require(r.composite.value)
        #expect(abs(v - 2.0 / 3.0) < 0.0051)
        #expect(r.weights == weights)
        #expect(r.components.map(\.weight) == [1, 1, 1])
        #expect(r.components.map(\.kind) == [.hrv, .restingHeartRate, .sleepDuration])
    }

    @Test func readinessBaselineUsesOnlyThePrevious28Nights() throws {
        var hrv = nights(Array(repeating: 4.0, count: 28), target: 4.1)
        hrv[AX.shift(target, -29)] = 9.0
        hrv[AX.shift(target, -40)] = 9.0
        hrv[AX.shift(target, 1)] = 9.0
        let r = compute(hrv: hrv)
        #expect(r.component(.hrv)?.baseline.value?.n == 28)
        #expect(r.component(.hrv)?.baseline.value?.mean == 4.0)
        #expect(abs((r.composite.value ?? 0) - 2) < 0.0051)
    }

    @Test func readinessCarriesNoAdviceText() {
        let banned = ["should", "recommend", "advice", "advise", "training", "workout", "rest day", "take it easy",
                      "push harder", "treatment", "go easy"]
        let results = [
            compute(hrv: nights(alternating(4.0, 4.02), target: 4.11), rhr: nights(alternating(50, 51), target: 52.5),
                    sleep: nights(alternating(420, 440), target: 490)),
            compute(hrv: nights(alternating(4.0, 4.02, 5), target: 4.1)),
            compute(hrv: [:]),
            compute(hrv: nights(Array(repeating: 4.0, count: 28), target: 3.0)),
        ]
        for r in results {
            var texts = Array(r.composite.inputs.values) + [r.composite.availability.explanation]
            for c in r.components { texts.append(c.availability.explanation) }
            for t in texts {
                for b in banned { #expect(!t.lowercased().contains(b), "advice-like wording: \(t)") }
            }
        }
    }

    @Test func readinessHostileInputsNeverTrap() {
        let hrv = nights(Array(repeating: 4.0, count: 28), target: 4.1)
        let weird: [LocalDay: Double?] = [target: .infinity, AX.shift(target, -1): .nan, AX.shift(target, -2): 1e308, AX.shift(target, -3): -1e308]
        for day in [AX.day(2026, 2, 30), AX.day(Int.max, 1, 1), AX.day(0, 0, 0), target] {
            let r = ReadinessCalculator.compute(day: day, calendar: AX.utc, lnRMSSD: hrv, restingHeartRate: weird, sleepDurationMinutes: weird)
            axCheck(r.composite)
            for c in r.components { if let z = c.z { #expect(z.isFinite) } }
        }
        let params = [ReadinessParameters(weights: ReadinessWeights(hrv: 0, restingHeartRate: 1, sleepDuration: 1)),
                      ReadinessParameters(weights: ReadinessWeights(hrv: .nan)),
                      ReadinessParameters(weights: ReadinessWeights(hrv: -1)),
                      ReadinessParameters(baselineDays: 0), ReadinessParameters(baselineDays: 100_000),
                      ReadinessParameters(lnRMSSDStandardDeviationFloor: 0), ReadinessParameters(bandThreshold: .nan)]
        for p in params {
            let r = ReadinessCalculator.compute(day: target, calendar: AX.utc, lnRMSSD: hrv, restingHeartRate: [:],
                                                sleepDurationMinutes: [:], parameters: p)
            axCheck(r.composite)
            if let v = r.composite.value { #expect(v.isFinite) }
        }
    }
}

// MARK: - Catalog, invariants, determinism, round trips

@Suite("Adversarial: catalog and cross-cutting invariants")
struct AdvCatalogInvariantTests {
    @Test func everySpecRequiredByTheModuleSpecExists() throws {
        let required = ["forma.hr.series", "forma.workout.summary", "forma.hr.zones", "forma.rhr.overnight", "forma.hrv.rmssd",
                        "forma.trends", "forma.sleep.candidate", "forma.load.edwards", "forma.readiness.experimental"]
        for id in required {
            let spec = try #require(MetricCatalog.spec(for: id), "missing spec \(id)")
            #expect(!spec.name.isEmpty && !spec.method.isEmpty && !spec.windowing.isEmpty && !spec.unit.isEmpty, "\(id)")
            #expect(!spec.requiredInputs.isEmpty, "\(id)")
            #expect(spec.version >= 1, "\(id)")
        }
        let ids = MetricCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate spec IDs")
        #expect(MetricCatalog.spec(for: "forma.sleep.candidate")?.status == .estimate)
        #expect(MetricCatalog.spec(for: "forma.readiness.experimental")?.status == .experimental)
        #expect(MetricCatalog.spec(for: "forma.load.edwards")?.name == "Forma Load (Edwards TRIMP)")
        #expect(MetricCatalog.spec(for: "no.such.metric") == nil)
    }

    @Test func defaultParametersMatchTheModuleSpec() {
        let r = RestingHeartRateParameters.default
        #expect(r.windowMillis == 300_000 && r.stepMillis == 60_000 && r.minimumWindowCoverage == 0.8)
        #expect(r.minimumCoveredMillis == 3 * AX.h && r.shortWindowThresholdMillis == 5 * AX.h && r.shortWindowMinimumCoverage == 0.6)
        let v = HRVParameters.default
        #expect(v.windowMillis == 300_000 && v.dropoutToleranceMillis == 2_000 && v.ruleBMaximumDeviation == 0.2)
        #expect(v.ruleBReferenceBeats == 5 && v.ruleBMinimumReferences == 3 && v.windowMinimumAcceptedFraction == 0.8)
        #expect(v.windowMinimumAcceptedMillis == 180_000 && v.windowMinimumPairs == 100 && v.minimumValidWindows == 6)
        #expect(BeatInterval.plausibleMillis == 300...2_000)
        let s = SleepDetectorParameters.default
        #expect(s.epochMillis == 60_000 && s.rollingMedianEpochs == 5 && s.thresholdPercentile == 0.10 && s.thresholdMultiplier == 2)
        #expect(s.mergeGapMillis == 10 * AX.m && s.minimumCandidateMillis == 3 * AX.h && s.minimumWakeBoutEpochs == 2)
        #expect(s.minimumMotionCoverage == 0.7 && s.minimumHeartRateCoverage == 0.5 && s.windowStartHour == 12)
        let p = ReadinessParameters.default
        #expect(p.baselineDays == 28 && p.hrvMinimumNights == 14 && p.restingHeartRateMinimumNights == 14 && p.sleepMinimumNights == 7)
        #expect(p.lnRMSSDStandardDeviationFloor == 0.05 && p.restingHeartRateStandardDeviationFloor == 1.0)
        #expect(p.sleepStandardDeviationFloorMinutes == 30 && p.bandThreshold == 1.0)
        #expect(p.weights == ReadinessWeights(hrv: 0.5, restingHeartRate: 0.3, sleepDuration: 0.2))
        let b = BaselineParameters.default
        #expect(b.windowDays == 28 && b.outlierMADMultiplier == 3 && b.madScale == 1.4826)
        #expect(HeartRateZones.defaultBoundaries == [0.5, 0.6, 0.7, 0.8, 0.9])
        #expect(TrainingLoad.edwardsBandLowerBounds == [0.5, 0.6, 0.7, 0.8, 0.9])
        #expect(TrainingLoad.edwardsWeights == [1, 2, 3, 4, 5])
        #expect(TrainingLoad.dailyMinimumCoverage == 0.3 && TrainingLoad.workoutMinimumCoverage == 0.5)
        #expect(TrainingLoad.banisterFemaleExponent == 1.67 && TrainingLoad.banisterMaleExponent == 1.92)
        #expect(HeartRateSeries.maxSpanMillis == 5_000 && HeartRateSeries.historyPrecedenceMillis == 5_000)
        #expect(HeartRateSeries.defaultMaxGapMillis == 10_000)
        #expect(TrendPeriod.allCases.map(\.minimumDaysWithData) == [4, 14, 45])
        #expect(TrendAnalyzer.recentDays == 7 && TrendAnalyzer.priorDays == 28)
        #expect(TrendAnalyzer.recentMinimumDays == 4 && TrendAnalyzer.priorMinimumDays == 14)
        #expect(MaxHeartRateResolver.tanakaIntercept == 208 && MaxHeartRateResolver.tanakaSlope == 0.7)
        #expect(MaxHeartRateResolver.missingInputDetail == "Set your max heart rate or birth year")
        #expect(SleepDetector.motionSensorName == "motion (accelerometer)")
    }

    func text(_ id: String) throws -> String {
        let s = try #require(MetricCatalog.spec(for: id), "missing spec \(id)")
        return ([s.name, s.unit, s.method, s.windowing, s.baseline ?? ""] + s.requiredInputs + s.qualityGates + s.limitations)
            .joined(separator: " | ")
    }

    @Test func catalogTextStatesTheSpecNumbers() throws {
        let expectations: [(String, [String])] = [
            ("forma.hr.series", ["5 s", "10 s", "outOfRange", "deviceMarkedInvalid", "noSensorContact", "clockUnmapped"]),
            ("forma.hr.zones", ["50%", "60%", "70%", "80%", "90%", "below zones", "Karvonen", "Set your max heart rate or birth year"]),
            ("forma.workout.summary", ["50%"]),
            ("forma.rhr.overnight", ["5 min", "1 min", "80%", "3 h", "60%", "5 h", "not a clinical"]),
            ("forma.hrv.rmssd", ["300", "2000", "20%", "80%", "180 s", "100", "PPG", "median"]),
            ("forma.trends", ["4", "14", "45", "7", "28"]),
            ("forma.baseline", ["28", "1.4826", "MAD"]),
            ("forma.sleep.candidate", ["P10", "10 min", "3 h", "70%", "50%", "motion (accelerometer)"]),
            ("forma.load.edwards", ["1, 2, 3, 4, 5", "30%", "50%"]),
            ("forma.readiness.experimental", ["0.05", "1.0", "30", "0.5", "0.3", "0.2", "14", "7", "28"]),
        ]
        for (id, needles) in expectations {
            let t = try text(id)
            for n in needles { #expect(t.contains(n), "\(id) does not state '\(n)'") }
        }
    }

    @Test func noParityClaimsWithProprietaryScores() throws {
        for spec in MetricCatalog.all {
            for t in [spec.name, spec.method, spec.windowing] + spec.limitations + spec.qualityGates {
                let l = t.lowercased()
                for claim in ["equivalent to whoop", "same as whoop", "matches whoop", "whoop-equivalent", "replicates whoop"] {
                    #expect(!l.contains(claim), "\(spec.id): \(t)")
                }
                if l.contains("whoop recovery") || l.contains("whoop strain") || l.contains("recovery score") || l.contains("strain score") {
                    #expect(l.contains("not"), "\(spec.id) mentions a proprietary score without disclaiming parity: \(t)")
                }
            }
        }
    }

    @Test func honestyInvariantsHoldAcrossTheWholeAPI() throws {
        var facts: [AXFacts] = []
        func add<V>(_ m: MetricValue<V>, _ label: String, windowed: Bool = true) { facts.append(AXFacts(m, label, windowed: windowed)) }
        let w = AX.t0 + 10 * AX.h
        let range = TimeRange(start: w, end: w + 1_800_000)
        let regimes: [(String, [HeartRateSample])] = [
            ("empty", []),
            ("flagged", AX.flag(AX.hrRun(w, count: 1_800) { _ in 140 }, .deviceMarkedInvalid)),
            ("sparse", AX.hrRun(w, count: 60, step: 30_000) { _ in 140 }),
            ("good", AX.hrRun(w - 23 * AX.h, count: 30 * 3_600) { k in 50 + k % 100 }),
        ]
        let zoneModels = [HeartRateZones(maxHeartRate: AX.hrMax(190)),
                          HeartRateZones(model: .heartRateReserve, maxHeartRate: AX.hrMax(190), restingHeartRate: 50),
                          HeartRateZones(maxHeartRate: nil)]
        for (name, hr) in regimes {
            for (zi, z) in zoneModels.enumerated() {
                let s = WorkoutAnalyzer.summarize(range: range, samples: hr, zones: z)
                add(s.meanHeartRate, "\(name)/\(zi) mean")
                add(s.maxHeartRate, "\(name)/\(zi) max")
                add(s.timeInZones, "\(name)/\(zi) zones")
                add(s.edwardsTRIMP, "\(name)/\(zi) trimp")
                add(s.zoneThresholds, "\(name)/\(zi) thresholds", windowed: false)
            }
            add(HeartRateSeries(hr).summary(in: range), "\(name) hr summary")
            add(RestingHeartRateEstimator.estimate(sleepWindow: TimeRange(start: w - 9 * AX.h, end: w - AX.h), samples: hr).restingHeartRate, "\(name) rhr")
            add(TrainingLoad.dailyLoad(day: AX.day(2026, 1, 5), calendar: AX.utc, samples: hr, hrMax: AX.hrMax(190)), "\(name) daily")
            for sex in [UserProfile.Sex.female, .male, .unspecified] {
                add(TrainingLoad.banisterTRIMP(range: range, samples: hr, hrMax: AX.hrMax(190), restingHeartRate: 50, sex: sex), "\(name) banister \(sex)")
            }
            let sleep = SleepSummary.fromConfirmedWindow(TimeRange(start: w - 9 * AX.h, end: w - AX.h), motion: nil, heartRate: hr)
            add(sleep.timeInBed, "\(name) tib")
            add(sleep.meanHeartRate, "\(name) sleep hr")
            add(sleep.continuity, "\(name) continuity")
        }
        for beats in [nil, [], AX.cycleWindows(start: AX.t0, amplitudes: [10, 12, 14, 16, 18, 20]),
                      AX.cycleWindows(start: AX.t0, amplitudes: [10, 12, 14])] as [[BeatInterval]?] {
            let r = HRVAnalyzer.analyze(beats: beats, range: TimeRange(start: AX.t0, end: AX.t0 + 30 * AX.m))
            add(r.rmssd, "hrv \(beats?.count ?? -1)")
            add(r.lnRMSSD, "ln \(beats?.count ?? -1)")
            add(r.rawRMSSD, "raw \(beats?.count ?? -1)")
        }
        let end = AX.day(2026, 3, 31)
        var series: [LocalDay: Double?] = [:]
        for (i, d) in AX.days(endingOn: end, count: 100, calendar: AX.utc).enumerated() where i % 3 != 0 { series[d] = Double(i % 11) }
        for values in [series, [:]] {
            for s in TrendAnalyzer.summaries(of: values, endingOn: end, calendar: AX.utc) { add(s.statistics, "trend \(s.period)") }
            add(TrendAnalyzer.recentVersusPrior(of: values, endingOn: end, calendar: AX.utc), "rvp")
            add(BaselineCalculator.baseline(values: values, targetDay: end, calendar: AX.utc), "baseline")
            let r = ReadinessCalculator.compute(day: end, calendar: AX.utc, lnRMSSD: values, restingHeartRate: values, sleepDurationMinutes: values)
            add(r.composite, "readiness")
            for c in r.components { add(c.baseline, "readiness baseline \(c.kind)") }
        }
        add(MaxHeartRateResolver.resolve(profile: UserProfile(), asOf: AX.t0, calendar: AX.utc), "hrmax none", windowed: false)
        add(MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1980), asOf: AX.t0, calendar: AX.utc), "hrmax age", windowed: false)
        let ws = AX.t0 + 12 * AX.h
        let motion = AX.motionMinutes(ws, ws + AX.d) { t in t >= AX.t0 + 23 * AX.h && t < AX.t0 + 31 * AX.h ? 0.003 : 0.08 }
        add(SleepDetector.detect(nightEndingOn: AX.day(2026, 1, 6), calendar: AX.utc, motion: motion), "sleep candidate")
        add(SleepDetector.detect(nightEndingOn: AX.day(2026, 1, 6), calendar: AX.utc, motion: nil), "sleep no motion")

        #expect(facts.count > 80)
        #expect(facts.contains { $0.available } && facts.contains { !$0.available })
        for f in facts {
            if f.available {
                #expect(f.hasValue && f.confidence != .none, "\(f.label)")
                #expect(!f.inputsEmpty, "\(f.label): an available result must list the inputs used")
                if f.windowed { #expect(f.hasWindow, "\(f.label): an available time-based result must state its window") }
            } else {
                #expect(!f.hasValue && f.confidence == .none, "\(f.label)")
            }
            #expect(f.specKnown, "\(f.label)")
            #expect(f.coverageOK, "\(f.label)")
            #expect(f.finite, "\(f.label)")
        }
    }

    @Test func resultsRoundTripThroughJSON() throws {
        func roundTrip<T: Codable & Equatable>(_ x: T, _ label: String) throws {
            let data = try JSONEncoder().encode(x)
            let back = try JSONDecoder().decode(T.self, from: data)
            #expect(back == x, "\(label) does not survive a JSON round trip")
        }
        let w = AX.t0 + 10 * AX.h
        let hr = AX.hrRun(w - 23 * AX.h, count: 30 * 3_600) { k in 50 + k % 100 }
        try roundTrip(WorkoutAnalyzer.summarize(range: TimeRange(start: w, end: w + AX.h), samples: hr,
                                                zones: HeartRateZones(maxHeartRate: AX.hrMax(190))), "workout")
        try roundTrip(RestingHeartRateEstimator.estimate(sleepWindow: TimeRange(start: w - 9 * AX.h, end: w - AX.h), samples: hr), "rhr")
        try roundTrip(HRVAnalyzer.analyze(beats: AX.cycleWindows(start: AX.t0, amplitudes: [10, 12, 14, 16, 18, 20]),
                                          range: TimeRange(start: AX.t0, end: AX.t0 + 30 * AX.m)), "hrv")
        let end = AX.day(2026, 3, 31)
        var values: [LocalDay: Double?] = [:]
        for (i, d) in AX.days(endingOn: end, count: 40, calendar: AX.utc).enumerated() { values[d] = 4 + Double(i % 5) / 100 }
        try roundTrip(TrendAnalyzer.summary(of: values, period: .days30, endingOn: end, calendar: AX.utc), "trend")
        try roundTrip(BaselineCalculator.baseline(values: values, targetDay: end, calendar: AX.utc), "baseline")
        try roundTrip(ReadinessCalculator.compute(day: end, calendar: AX.utc, lnRMSSD: values, restingHeartRate: [:], sleepDurationMinutes: [:]), "readiness")
        let ws = AX.t0 + 12 * AX.h
        let motion = AX.motionMinutes(ws, ws + AX.d) { t in t >= AX.t0 + 23 * AX.h && t < AX.t0 + 31 * AX.h ? 0.003 : 0.08 }
        try roundTrip(SleepDetector.detect(nightEndingOn: AX.day(2026, 1, 6), calendar: AX.utc, motion: motion, heartRate: hr), "sleep")
        try roundTrip(SleepSummary.fromConfirmedWindow(TimeRange(start: AX.t0 + 23 * AX.h, end: AX.t0 + 31 * AX.h), motion: motion, heartRate: hr), "summary")
        try roundTrip(MetricCatalog.all, "catalog")
    }

    @Test func resultsDoNotDependOnInputOrderOrConcurrency() async {
        var rng = AdvRNG(seed: 77)
        let w = AX.t0 + 10 * AX.h
        var hr: [HeartRateSample] = []
        for k in 0..<7_200 {
            let t = w - AX.h + Int64(k) * 1_000 + Int64.random(in: 0..<900, using: &rng)
            let source: MeasurementSource = [.deviceHistory, .liveVendorStream, .standardHeartRateService][k % 3]
            if Int.random(in: 0..<20, using: &rng) == 0 { continue }
            hr.append(AX.hr(t, Int.random(in: 60...180, using: &rng), source))
        }
        let ordered = hr
        let shuffled = hr.shuffled(using: &rng)
        let range = TimeRange(start: w, end: w + 30 * AX.m)
        let zones = HeartRateZones(maxHeartRate: AX.hrMax(190))
        let reference = WorkoutAnalyzer.summarize(range: range, samples: ordered, zones: zones)
        #expect(WorkoutAnalyzer.summarize(range: range, samples: shuffled, zones: zones) == reference)
        #expect(RestingHeartRateEstimator.estimate(sleepWindow: TimeRange(start: w - AX.h, end: w + AX.h), samples: shuffled)
                == RestingHeartRateEstimator.estimate(sleepWindow: TimeRange(start: w - AX.h, end: w + AX.h), samples: hr))
        #expect(TrainingLoad.dailyLoad(day: AX.day(2026, 1, 5), calendar: AX.utc, samples: shuffled, hrMax: AX.hrMax(190))
                == TrainingLoad.dailyLoad(day: AX.day(2026, 1, 5), calendar: AX.utc, samples: hr, hrMax: AX.hrMax(190)))
        let results = await withTaskGroup(of: WorkoutSummary.self) { group in
            for i in 0..<8 {
                let input = i % 2 == 0 ? ordered : shuffled
                group.addTask { WorkoutAnalyzer.summarize(range: range, samples: input, zones: zones) }
            }
            var out: [WorkoutSummary] = []
            for await r in group { out.append(r) }
            return out
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == reference })
    }
}

// MARK: - Trap resistance (child processes, so a trap is reported instead of ending the test run)

#if os(macOS) || os(Linux) || os(Windows)
@Suite("Adversarial: trap resistance")
struct AdvTrapTests {
    // IMPLEMENTATION BUG: `RestingHeartRateParameters.isValid` only checks `stepMillis >= 1_000`; with a huge step
    // the window loop computes `start += stepMillis` and overflows Int64, trapping the process (spec: never crash
    // on malformed input). A huge step should simply evaluate one window (or be rejected as invalid parameters).
    @Test("IMPLEMENTATION BUG: a huge RHR step must not trap")
    func restingHeartRateWithAHugeStepDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let start: EpochMillis = 1_767_571_200_000 + 23 * 3_600_000
            let samples = (0..<(8 * 3_600)).map {
                HeartRateSample(deviceID: "b", timestamp: start + Int64($0) * 1_000, bpm: 60, source: .deviceHistory, receivedAt: start)
            }
            let window = TimeRange(start: start, end: start + 8 * 3_600_000)
            _ = RestingHeartRateEstimator.estimate(sleepWindow: window, samples: samples, parameters: RestingHeartRateParameters(stepMillis: .max))
            _ = RestingHeartRateEstimator.estimate(sleepWindow: window, samples: samples,
                                                   parameters: RestingHeartRateParameters(stepMillis: .max - 1_000_000))
        }
    }

    @Test func otherExtremeParametersDoNotTrap() async {
        await #expect(processExitsWith: .success) {
            let t0: EpochMillis = 1_767_571_200_000
            let samples = (0..<(8 * 3_600)).map {
                HeartRateSample(deviceID: "b", timestamp: t0 + Int64($0) * 1_000, bpm: 55 + $0 % 30, source: .deviceHistory, receivedAt: t0)
            }
            let window = TimeRange(start: t0, end: t0 + 8 * 3_600_000)
            for p in [RestingHeartRateParameters(windowMillis: 1, stepMillis: 1_000),
                      RestingHeartRateParameters(minimumCoveredMillis: .max, shortWindowThresholdMillis: .max),
                      RestingHeartRateParameters(windowMillis: .max, maximumSleepWindowMillis: .max),
                      RestingHeartRateParameters(minimumWindowCoverage: .nan), RestingHeartRateParameters(stepMillis: .min),
                      RestingHeartRateParameters(windowMillis: .min, minimumCoveredMillis: .min, shortWindowThresholdMillis: .min)] {
                _ = RestingHeartRateEstimator.estimate(sleepWindow: window, samples: samples, parameters: p)
            }
            var beats: [BeatInterval] = []
            var t = t0
            for i in 0..<9_000 {
                t += 1_000 + Int64(i % 3) * 10
                beats.append(BeatInterval(deviceID: "b", timestamp: t, intervalMillis: Double(1_000 + (i % 3) * 10), source: .deviceHistory,
                                          recordKey: t, indexInRecord: i, receivedAt: t, timingBasis: .reconstructedFromRecordTime))
            }
            for p in [HRVParameters(windowMillis: .max), HRVParameters(windowMillis: 10_000, maximumAnalysisMillis: 7 * 86_400_000),
                      HRVParameters(ruleBReferenceBeats: 50, ruleBMinimumReferences: 50), HRVParameters(windowMinimumPairs: .max),
                      HRVParameters(minimumValidWindows: .max), HRVParameters(windowMillis: .min), HRVParameters(maximumAnalysisMillis: .max),
                      HRVParameters(dropoutToleranceMillis: 1e308), HRVParameters(windowMinimumAcceptedMillis: -.infinity)] {
                _ = HRVAnalyzer.analyze(beats: beats, range: window, parameters: p)
            }
            let ws = t0 + 12 * 3_600_000
            let motion = stride(from: ws, to: ws + 86_400_000, by: 60_000).map {
                MotionEpoch(deviceID: "b", timestamp: $0, epochMillis: 60_000, activity: ($0 / 60_000) % 3 == 0 ? 0.08 : 0.003,
                            sampleCount: 10, source: .deviceHistory)
            }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
            for p in [SleepDetectorParameters(mergeGapMillis: .max, minimumCandidateMillis: .max, minimumOutsideHeartRateMillis: .max),
                      SleepDetectorParameters(mergeGapMillis: .min, minimumCandidateMillis: .min, minimumWakeBoutEpochs: .min),
                      SleepDetectorParameters(epochMillis: .max), SleepDetectorParameters(epochMillis: .min),
                      SleepDetectorParameters(rollingMedianEpochs: .max), SleepDetectorParameters(windowStartHour: .max),
                      SleepDetectorParameters(maximumConfirmedWindowMillis: .max), SleepDetectorParameters(minimumWakeBoutEpochs: .max)] {
                _ = SleepDetector.detect(nightEndingOn: LocalDay(year: 2026, month: 1, day: 6), calendar: cal, motion: motion,
                                         heartRate: samples, parameters: p)
                _ = SleepSummary.fromConfirmedWindow(TimeRange(start: ws, end: ws + 8 * 3_600_000), motion: motion, heartRate: samples, parameters: p)
            }
            let day = LocalDay(year: 2026, month: 3, day: 31)
            let values: [LocalDay: Double?] = [LocalDay(year: 2026, month: 3, day: 30): 1, LocalDay(year: 2026, month: 3, day: 29): 2]
            for p in [BaselineParameters(windowDays: .max, minimumDays: .max), BaselineParameters(windowDays: .min, minimumDays: .min),
                      BaselineParameters(windowDays: 366, minimumDays: 1)] {
                _ = BaselineCalculator.baseline(values: values, targetDay: day, calendar: cal, parameters: p)
            }
            for p in [ReadinessParameters(baselineDays: .max), ReadinessParameters(baselineDays: .min),
                      ReadinessParameters(hrvMinimumNights: .max, highConfidenceMinimumHRVNights: .max),
                      ReadinessParameters(weights: ReadinessWeights(hrv: .greatestFiniteMagnitude, restingHeartRate: .greatestFiniteMagnitude,
                                                                    sleepDuration: .greatestFiniteMagnitude))] {
                _ = ReadinessCalculator.compute(day: day, calendar: cal, lnRMSSD: values, restingHeartRate: values,
                                                sleepDurationMinutes: values, parameters: p)
            }
            _ = HeartRateZones(boundaries: Array(repeating: 0.5, count: 100_000), maxHeartRate: MaxHeartRate(bpm: 190, basis: .userOverride)).thresholds()
            _ = TrendAnalyzer.summaries(of: values, endingOn: LocalDay(year: 2200, month: 12, day: 31), calendar: cal)
            _ = TrendAnalyzer.summaries(of: values, endingOn: LocalDay(year: 1, month: 1, day: 1), calendar: cal)
        }
    }
}
#endif
