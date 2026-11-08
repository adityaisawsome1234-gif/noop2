import FormaCore

/// The interval one usable sample is assumed to describe (see ``HeartRateSeries``).
public struct HeartRateCoverageSpan: Hashable, Sendable, Codable {
    /// `[t, t + min(gap to the next sample, 5 s))`, clipped to the query window when one was given.
    public var range: TimeRange
    /// Heart rate of the owning sample, in bpm.
    public var bpm: Int

    public init(range: TimeRange, bpm: Int) {
        self.range = range
        self.bpm = bpm
    }
}

/// A run of canonical samples in which consecutive samples are at most `maxGapMillis` apart.
/// Charts draw one line per segment, so gaps stay visible and are never interpolated.
public struct HeartRateSegment: Hashable, Sendable {
    /// Samples in time order; never empty.
    public let samples: [HeartRateSample]
    /// Timestamp of the first sample (epoch ms).
    public let firstTimestamp: EpochMillis
    /// Timestamp of the last sample (epoch ms).
    public let lastTimestamp: EpochMillis
}

/// Time-weighted description of the canonical series inside one window (spec `forma.hr.series`).
public struct HeartRateWindowSummary: Hashable, Sendable, Codable {
    /// Time-weighted mean over the coverage spans inside the window, bpm, rounded to 0.1.
    public var meanBPM: Double
    /// Lowest and highest usable sample inside the window, bpm.
    public var minimumBPM: Int
    public var maximumBPM: Int
    /// Usable samples whose timestamp lies inside the window.
    public var sampleCount: Int
    /// Covered time inside the window, ms.
    public var coveredMillis: Int64
    /// Chart segments (10 s gap rule) inside the window.
    public var segmentCount: Int

    public init(meanBPM: Double, minimumBPM: Int, maximumBPM: Int, sampleCount: Int, coveredMillis: Int64, segmentCount: Int) {
        self.meanBPM = meanBPM
        self.minimumBPM = minimumBPM
        self.maximumBPM = maximumBPM
        self.sampleCount = sampleCount
        self.coveredMillis = coveredMillis
        self.segmentCount = segmentCount
    }
}

/// The canonical heart-rate series every Forma analysis uses (spec `forma.hr.series`).
///
/// `init(_:)` applies ``usable(_:)`` and ``canonical(_:)``: ``samples`` are usable, merged across
/// sources, sorted by time and unique per timestamp. Samples are treated as one wearer's series
/// regardless of `deviceID`; pass one wearer's data.
///
/// **Coverage model (assumption).** A sample is assumed to describe the heart rate from its timestamp
/// until the next sample, but for at most ``maxSpanMillis`` (5 s): the band and the standard Heart
/// Rate Service report about once per second, so a longer silence is missing data, not a
/// continuation of the last value. `coverage(in:)` = covered ms / window ms. A sample shortly before
/// a window can therefore cover the window's first seconds.
public struct HeartRateSeries: Hashable, Sendable {
    /// Quality flags that make a sample unusable for analytics (the raw record is kept in storage).
    /// `.unvalidatedField` is included: a value decoded from a field whose meaning is not yet validated
    /// for the firmware never enters a series, coverage, zones or any metric. Once a field is validated,
    /// the ingest or feature layer should stop setting (or remove) the flag.
    /// `.nearClockDiscontinuity` is included too: next to a band clock change or restart the record's absolute
    /// time is uncertain (METHODOLOGY §2).
    public static let excludedFlags: QualityFlags = [.outOfRange, .deviceMarkedInvalid, .noSensorContact, .clockUnmapped,
                                                     .unvalidatedField, .nearClockDiscontinuity]
    /// Longest time one sample may stand for, ms.
    public static let maxSpanMillis: Int64 = 5_000
    /// Non-history samples within ± this many ms of a usable band-history sample are dropped.
    public static let historyPrecedenceMillis: Int64 = 5_000
    /// Default chart gap: consecutive samples further apart than this start a new segment, ms.
    public static let defaultMaxGapMillis: Int64 = 10_000

    /// Canonical samples: usable, merged, ascending, one per timestamp.
    public let samples: [HeartRateSample]
    let index: CoverageIndex

    /// Builds the canonical series from raw samples of any source (unusable samples are dropped).
    public init(_ samples: [HeartRateSample]) {
        let canonical = Self.canonical(samples)
        self.samples = canonical
        self.index = CoverageIndex(samples: canonical, maxSpanMillis: Self.maxSpanMillis)
    }

    public static func == (lhs: HeartRateSeries, rhs: HeartRateSeries) -> Bool { lhs.samples == rhs.samples }
    public func hash(into hasher: inout Hasher) { hasher.combine(samples) }

    public var isEmpty: Bool { samples.isEmpty }

    // MARK: Usability and merging

    /// True when the sample may enter analytics: none of ``excludedFlags`` (outOfRange, deviceMarkedInvalid,
    /// noSensorContact, clockUnmapped, unvalidatedField), bpm within `HeartRateSample.plausibleRange`
    /// (25–240), and a timestamp within ±2^52 ms of the epoch.
    public static func isUsable(_ sample: HeartRateSample) -> Bool {
        sample.quality.isDisjoint(with: excludedFlags)
            && HeartRateSample.plausibleRange.contains(sample.bpm)
            && Sanity.isSane(sample.timestamp)
    }

    /// The usable subset, in input order.
    public static func usable(_ samples: [HeartRateSample]) -> [HeartRateSample] {
        samples.filter(isUsable)
    }

    /// Merges usable samples from all sources into one series.
    ///
    /// 1. Unusable samples are removed first, so a flagged history record never suppresses a usable one.
    /// 2. Band history wins wherever it exists: any other sample within ±5 s (inclusive) of a usable
    ///    history sample is dropped.
    /// 3. Among the remaining samples, in each whole UTC second (`floor(t / 1000 ms)`) only the best
    ///    source present is kept: live vendor stream > backup import > standard Heart Rate Service > demo.
    /// 4. Output is sorted by time with one sample per timestamp; exact-timestamp ties keep history >
    ///    live > backup > standard > demo, then the earliest `receivedAt`, then `deviceID`, then the lower bpm.
    public static func canonical(_ samples: [HeartRateSample]) -> [HeartRateSample] {
        var history: [HeartRateSample] = []
        var others: [HeartRateSample] = []
        for s in samples where isUsable(s) {
            if s.source == .deviceHistory { history.append(s) } else { others.append(s) }
        }
        if !history.isEmpty {
            let historyTimes = history.map(\.timestamp).sorted()
            others.removeAll { hasHistory(near: $0.timestamp, in: historyTimes) }
        }
        var bestRankBySecond: [Int64: Int] = [:]
        for s in others {
            let second = IntMath.floorDiv(s.timestamp, 1_000)
            let rank = sourceRank(s.source)
            if let best = bestRankBySecond[second], best <= rank { continue }
            bestRankBySecond[second] = rank
        }
        others.removeAll { sourceRank($0.source) != bestRankBySecond[IntMath.floorDiv($0.timestamp, 1_000)] }

        var merged = history + others
        merged.sort(by: canonicalOrder)
        var out: [HeartRateSample] = []
        out.reserveCapacity(merged.count)
        for s in merged where out.last?.timestamp != s.timestamp {
            out.append(s)
        }
        return out
    }

    /// Precedence used for same-second and same-timestamp conflicts (lower wins).
    static func sourceRank(_ source: MeasurementSource) -> Int {
        switch source {
        case .deviceHistory: return 0
        case .liveVendorStream: return 1
        case .backupImport: return 2
        case .standardHeartRateService: return 3
        case .demo: return 4
        }
    }

    private static func hasHistory(near t: EpochMillis, in sortedTimes: [EpochMillis]) -> Bool {
        let i = Search.lowerBound(sortedTimes, t - historyPrecedenceMillis)
        return i < sortedTimes.count && sortedTimes[i] <= t + historyPrecedenceMillis
    }

    /// Total order that makes the merge independent of input order.
    private static func canonicalOrder(_ a: HeartRateSample, _ b: HeartRateSample) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
        let ra = sourceRank(a.source), rb = sourceRank(b.source)
        if ra != rb { return ra < rb }
        if a.receivedAt != b.receivedAt { return a.receivedAt < b.receivedAt }
        if a.deviceID != b.deviceID { return a.deviceID < b.deviceID }
        if a.bpm != b.bpm { return a.bpm < b.bpm }
        let da = a.deviceTimeRaw ?? .min, db = b.deviceTimeRaw ?? .min
        if da != db { return da < db }
        let ba = a.batchID ?? .min, bb = b.batchID ?? .min
        if ba != bb { return ba < bb }
        return a.quality.rawValue < b.quality.rawValue
    }

    // MARK: Queries

    /// Canonical samples whose timestamp lies in `range` (empty for an invalid range).
    public func samples(in range: TimeRange) -> ArraySlice<HeartRateSample> {
        guard Sanity.isSane(range), !range.isEmpty else { return samples[0..<0] }
        let lo = Search.lowerBound(index.starts, range.start)
        let hi = Search.lowerBound(index.starts, range.end)
        return samples[lo..<max(lo, hi)]
    }

    /// Splits the series (optionally only the samples inside `range`) wherever consecutive samples are
    /// more than `maxGapMillis` apart. A gap of exactly `maxGapMillis` does not split.
    public func segments(in range: TimeRange? = nil,
                         maxGapMillis: Int64 = HeartRateSeries.defaultMaxGapMillis) -> [HeartRateSegment] {
        let slice = range.map { samples(in: $0) } ?? samples[...]
        var out: [HeartRateSegment] = []
        var current: [HeartRateSample] = []
        var first: EpochMillis = 0
        var last: EpochMillis = 0
        for s in slice {
            if !current.isEmpty, s.timestamp - last > maxGapMillis {
                out.append(HeartRateSegment(samples: current, firstTimestamp: first, lastTimestamp: last))
                current = []
            }
            if current.isEmpty { first = s.timestamp }
            current.append(s)
            last = s.timestamp
        }
        if !current.isEmpty {
            out.append(HeartRateSegment(samples: current, firstTimestamp: first, lastTimestamp: last))
        }
        return out
    }

    /// Coverage spans of all samples, or clipped to `range` when given.
    public func coverageSpans(in range: TimeRange? = nil) -> [HeartRateCoverageSpan] {
        guard let range else {
            return index.starts.indices.map {
                HeartRateCoverageSpan(range: TimeRange(start: index.starts[$0], end: index.ends[$0]), bpm: index.bpms[$0])
            }
        }
        var out: [HeartRateCoverageSpan] = []
        index.forEachOverlap(range) { i, start, end in
            out.append(HeartRateCoverageSpan(range: TimeRange(start: start, end: end), bpm: index.bpms[i]))
        }
        return out
    }

    /// Covered time inside `range`, ms. An empty range covers 0 ms; an invalid range (timestamps beyond
    /// ±2^52 ms) is not evaluated and also gives 0, so use ``coverage(in:)`` (nil for both) to tell them apart.
    public func coveredMillis(in range: TimeRange) -> Int64 {
        index.integrate(range).covered
    }

    /// Covered ms / window ms, in 0…1; nil for an empty or invalid window.
    public func coverage(in range: TimeRange) -> Double? {
        guard Sanity.isSane(range), !range.isEmpty else { return nil }
        return Double(index.integrate(range).covered) / Double(range.durationMillis)
    }

    /// Time-weighted mean heart rate inside `range` (bpm, unrounded); nil when nothing is covered.
    /// A building block without coverage or confidence: show ``summary(in:)`` to people instead.
    public func timeWeightedMean(in range: TimeRange) -> Double? {
        let (covered, weighted) = index.integrate(range)
        guard covered > 0 else { return nil }
        return Double(weighted) / Double(covered)
    }

    /// Mean / min / max with coverage for one window. Available when at least one usable sample lies
    /// inside the window; confidence follows coverage (≥ 90 % high, ≥ 70 % moderate, otherwise low).
    public func summary(in range: TimeRange) -> MetricValue<HeartRateWindowSummary> {
        let spec = MetricCatalog.heartRateSeries
        guard Sanity.isSane(range), !range.isEmpty else {
            return spec.unavailable(.insufficientData(detail: "The time window is empty or invalid"), window: nil)
        }
        let inside = samples(in: range)
        let (covered, weighted) = index.integrate(range)
        let coverage = Double(covered) / Double(range.durationMillis)
        var inputs = ["usableSamples": "\(inside.count)", "coverage": Fmt.percent(coverage),
                      "spanAssumption": "each sample covers up to 5 s"]
        guard !inside.isEmpty, covered > 0 else {
            return spec.unavailable(.insufficientData(detail: "No usable heart-rate samples in this window"),
                                    coverage: coverage, window: range, inputs: inputs)
        }
        var lo = Int.max, hi = Int.min
        for s in inside {
            lo = min(lo, s.bpm)
            hi = max(hi, s.bpm)
        }
        let segmentCount = segments(in: range).count
        inputs["segments"] = "\(segmentCount)"
        let summary = HeartRateWindowSummary(meanBPM: Stats.rounded(Double(weighted) / Double(covered), decimals: 1),
                                             minimumBPM: lo, maximumBPM: hi, sampleCount: inside.count,
                                             coveredMillis: covered, segmentCount: segmentCount)
        return spec.available(summary, coverage: coverage, confidence: .forAvailable(coverage: coverage),
                              window: range, inputs: inputs)
    }
}

// MARK: - Coverage index

/// Prefix sums over the (non-overlapping, ascending) coverage spans of a canonical series, giving
/// O(log n) covered-time and time-weighted-sum queries for any window.
struct CoverageIndex: Sendable {
    let starts: [Int64]
    let ends: [Int64]
    let bpms: [Int]
    /// prefixCovered[i] = total span length of spans 0..<i (ms).
    let prefixCovered: [Int64]
    /// prefixWeighted[i] = Σ bpm × length over spans 0..<i (bpm·ms, exact in Int64).
    let prefixWeighted: [Int64]

    init(samples: [HeartRateSample], maxSpanMillis: Int64) {
        let n = samples.count
        var starts: [Int64] = [], ends: [Int64] = [], bpms: [Int] = []
        starts.reserveCapacity(n)
        ends.reserveCapacity(n)
        bpms.reserveCapacity(n)
        var pc = [Int64](repeating: 0, count: n + 1)
        var pw = [Int64](repeating: 0, count: n + 1)
        for i in 0..<n {
            let t = samples[i].timestamp
            let length = i + 1 < n ? min(samples[i + 1].timestamp - t, maxSpanMillis) : maxSpanMillis
            starts.append(t)
            ends.append(t + length)
            bpms.append(samples[i].bpm)
            pc[i + 1] = pc[i] + length
            pw[i + 1] = pw[i] + Int64(samples[i].bpm) * length
        }
        self.starts = starts
        self.ends = ends
        self.bpms = bpms
        self.prefixCovered = pc
        self.prefixWeighted = pw
    }

    /// Indices of spans overlapping `range` (empty for an empty or invalid range).
    func overlapping(_ range: TimeRange) -> Range<Int> {
        guard Sanity.isSane(range), !range.isEmpty, !starts.isEmpty else { return 0..<0 }
        let i0 = Search.upperBound(ends, range.start)
        let i1 = Search.lowerBound(starts, range.end)
        return i0 < i1 ? i0..<i1 : 0..<0
    }

    /// Covered ms and Σ bpm·ms inside `range`.
    func integrate(_ range: TimeRange) -> (covered: Int64, weighted: Int64) {
        let idx = overlapping(range)
        guard let first = idx.first, let last = idx.last else { return (0, 0) }
        var covered = prefixCovered[idx.upperBound] - prefixCovered[first]
        var weighted = prefixWeighted[idx.upperBound] - prefixWeighted[first]
        let front = max(0, range.start - starts[first])
        covered -= front
        weighted -= Int64(bpms[first]) * front
        let back = max(0, ends[last] - range.end)
        covered -= back
        weighted -= Int64(bpms[last]) * back
        return (covered, weighted)
    }

    /// Calls `body(spanIndex, clippedStart, clippedEnd)` for every span overlapping `range`.
    func forEachOverlap(_ range: TimeRange, _ body: (Int, Int64, Int64) -> Void) {
        for i in overlapping(range) {
            let s = max(starts[i], range.start)
            let e = min(ends[i], range.end)
            if e > s { body(i, s, e) }
        }
    }
}
