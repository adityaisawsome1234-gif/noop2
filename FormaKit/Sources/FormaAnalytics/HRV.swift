import Foundation
import FormaCore

/// Tunable parameters of the RMSSD analysis (defaults = spec `forma.hrv.rmssd`).
public struct HRVParameters: Hashable, Sendable, Codable {
    /// Analysis window length, ms (5 min), aligned to the analysis start.
    public var windowMillis: Int64
    /// A new segment starts when Δt to the previous beat exceeds the beat's own interval by more than this, ms.
    public var dropoutToleranceMillis: Double
    /// Rule B rejects an interval deviating from the reference median by more than this fraction.
    public var ruleBMaximumDeviation: Double
    /// Rule B reference: the median of the last ≤ this many accepted intervals of the segment (1…50).
    public var ruleBReferenceBeats: Int
    /// Rule B applies only once the segment has at least this many accepted reference intervals.
    public var ruleBMinimumReferences: Int
    /// A window is valid only if at least this fraction of its beats is accepted…
    public var windowMinimumAcceptedFraction: Double
    /// …its accepted intervals sum to at least this many ms (180 s)…
    public var windowMinimumAcceptedMillis: Double
    /// …and it has at least this many successive pairs.
    public var windowMinimumPairs: Int
    /// Valid windows required for a period value.
    public var minimumValidWindows: Int
    /// Longer analysis periods are rejected as malformed, ms (24 h; at most 7 days).
    public var maximumAnalysisMillis: Int64
    /// Confidence: high when valid/total windows ≥ this and the artifact rate ≤ `highConfidenceMaximumArtifactRate`.
    public var highConfidenceMinimumCoverage: Double
    public var highConfidenceMaximumArtifactRate: Double
    /// Confidence: moderate when valid/total windows ≥ this and the artifact rate ≤ `moderateConfidenceMaximumArtifactRate`; otherwise low.
    public var moderateConfidenceMinimumCoverage: Double
    public var moderateConfidenceMaximumArtifactRate: Double

    public init(windowMillis: Int64 = 300_000, dropoutToleranceMillis: Double = 2_000, ruleBMaximumDeviation: Double = 0.20,
                ruleBReferenceBeats: Int = 5, ruleBMinimumReferences: Int = 3, windowMinimumAcceptedFraction: Double = 0.80,
                windowMinimumAcceptedMillis: Double = 180_000, windowMinimumPairs: Int = 100, minimumValidWindows: Int = 6,
                maximumAnalysisMillis: Int64 = 24 * 3_600_000, highConfidenceMinimumCoverage: Double = 0.7,
                highConfidenceMaximumArtifactRate: Double = 0.05, moderateConfidenceMinimumCoverage: Double = 0.4,
                moderateConfidenceMaximumArtifactRate: Double = 0.15) {
        self.windowMillis = windowMillis
        self.dropoutToleranceMillis = dropoutToleranceMillis
        self.ruleBMaximumDeviation = ruleBMaximumDeviation
        self.ruleBReferenceBeats = ruleBReferenceBeats
        self.ruleBMinimumReferences = ruleBMinimumReferences
        self.windowMinimumAcceptedFraction = windowMinimumAcceptedFraction
        self.windowMinimumAcceptedMillis = windowMinimumAcceptedMillis
        self.windowMinimumPairs = windowMinimumPairs
        self.minimumValidWindows = minimumValidWindows
        self.maximumAnalysisMillis = maximumAnalysisMillis
        self.highConfidenceMinimumCoverage = highConfidenceMinimumCoverage
        self.highConfidenceMaximumArtifactRate = highConfidenceMaximumArtifactRate
        self.moderateConfidenceMinimumCoverage = moderateConfidenceMinimumCoverage
        self.moderateConfidenceMaximumArtifactRate = moderateConfidenceMaximumArtifactRate
    }

    public static let `default` = HRVParameters()

    /// Largest rule-B reference set: the median is recomputed for every beat, so this bounds the work per beat.
    static let maximumRuleBReferenceBeats = 50

    var isValid: Bool {
        let fractions = [ruleBMaximumDeviation, windowMinimumAcceptedFraction, highConfidenceMinimumCoverage,
                         highConfidenceMaximumArtifactRate, moderateConfidenceMinimumCoverage, moderateConfidenceMaximumArtifactRate]
        return windowMillis >= 10_000 && maximumAnalysisMillis > 0 && maximumAnalysisMillis <= 7 * 24 * 3_600_000
            && dropoutToleranceMillis.isFinite && dropoutToleranceMillis >= 0
            && ruleBReferenceBeats >= 1 && ruleBReferenceBeats <= Self.maximumRuleBReferenceBeats
            && ruleBMinimumReferences >= 1 && ruleBMinimumReferences <= ruleBReferenceBeats
            && windowMinimumAcceptedMillis.isFinite && windowMinimumAcceptedMillis >= 0
            && windowMinimumPairs >= 1 && minimumValidWindows >= 1
            && fractions.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
}

/// Rejected beats by reason, counted over the analysed windows.
public struct HRVArtifactCounts: Hashable, Sendable, Codable {
    /// Rule A: interval outside `BeatInterval.plausibleMillis` (300–2000 ms), non-finite, or flagged `outOfRange`.
    public var ruleA: Int
    /// Rule B: |interval − median(last ≤ 5 accepted in segment)| > 20 % of that median (after ≥ 3 references).
    public var ruleB: Int
    /// Flagged by the device or ingest: `deviceMarkedInvalid`, `noSensorContact`, `clockUnmapped` or `unvalidatedField`.
    public var flagged: Int

    public init(ruleA: Int = 0, ruleB: Int = 0, flagged: Int = 0) {
        self.ruleA = ruleA
        self.ruleB = ruleB
        self.flagged = flagged
    }

    /// All rejected beats. Saturates at `Int.max` instead of trapping on corrupted decoded values.
    public var total: Int { IntMath.saturatingSum([ruleA, ruleB, flagged]) }
}

/// One 5-minute analysis window.
public struct HRVWindow: Hashable, Sendable, Codable {
    public var range: TimeRange
    /// All analysed beats whose timestamp lies in the window (accepted and rejected).
    public var beats: Int
    public var acceptedBeats: Int
    /// Sum of accepted intervals, ms.
    public var acceptedIntervalMillis: Double
    /// Successive differences between two accepted, adjacent, same-segment beats both inside the window.
    public var successivePairs: Int
    /// sqrt(mean(diff²)), ms, rounded to 0.1; nil unless the window is valid.
    public var rmssd: Double?
    public var isValid: Bool
    /// First failed validity rule, for invalid windows.
    public var invalidReason: String?

    public init(range: TimeRange, beats: Int, acceptedBeats: Int, acceptedIntervalMillis: Double,
                successivePairs: Int, rmssd: Double?, isValid: Bool, invalidReason: String?) {
        self.range = range
        self.beats = beats
        self.acceptedBeats = acceptedBeats
        self.acceptedIntervalMillis = acceptedIntervalMillis
        self.successivePairs = successivePairs
        self.rmssd = rmssd
        self.isValid = isValid
        self.invalidReason = invalidReason
    }
}

/// Result of ``HRVAnalyzer/analyze(beats:range:parameters:)``.
///
/// The counts describe what was analysed. With no beat source (`beats: nil`) the period's windows are
/// still listed, each with no beats. Every count is 0 and `windows` is empty only when nothing could be
/// analysed: invalid parameters, an empty or invalid period, or one longer than `maximumAnalysisMillis`.
public struct HRVAnalysis: Hashable, Sendable, Codable {
    public var range: TimeRange
    /// Median of valid-window RMSSDs, ms, rounded to 0.1 (spec `forma.hrv.rmssd`).
    public var rmssd: MetricValue<Double>
    /// Natural log of the (unrounded) period RMSSD in ms, rounded to 0.001 (spec `forma.hrv.lnrmssd`, unit ln(ms)).
    public var lnRMSSD: MetricValue<Double>
    /// DIAGNOSTIC ONLY: RMSSD of all adjacent in-segment pairs with no artifact rejection, ms
    /// (spec `forma.hrv.rmssd.raw`, listed in ``MetricCatalog/diagnosticSpecIDs``). Never use it as a wellness value.
    public var rawRMSSD: MetricValue<Double>
    /// Analysed beats in the analysed windows (after duplicate removal; beats in a trailing partial window are not counted).
    public var totalBeats: Int
    public var acceptedBeats: Int
    /// accepted / total beats; nil when there are no beats.
    public var acceptedFraction: Double?
    public var artifacts: HRVArtifactCounts
    /// Segments found among the analysed beats of the period.
    public var segmentCount: Int
    public var validWindows: Int
    public var totalWindows: Int
    public var windows: [HRVWindow]
    public var parameters: HRVParameters

    public init(range: TimeRange, rmssd: MetricValue<Double>, lnRMSSD: MetricValue<Double>, rawRMSSD: MetricValue<Double>,
                totalBeats: Int, acceptedBeats: Int, acceptedFraction: Double?, artifacts: HRVArtifactCounts,
                segmentCount: Int, validWindows: Int, totalWindows: Int, windows: [HRVWindow], parameters: HRVParameters) {
        self.range = range
        self.rmssd = rmssd
        self.lnRMSSD = lnRMSSD
        self.rawRMSSD = rawRMSSD
        self.totalBeats = totalBeats
        self.acceptedBeats = acceptedBeats
        self.acceptedFraction = acceptedFraction
        self.artifacts = artifacts
        self.segmentCount = segmentCount
        self.validWindows = validWindows
        self.totalWindows = totalWindows
        self.windows = windows
        self.parameters = parameters
    }
}

/// RMSSD from device-provided beat intervals only (never from heart rate).
///
/// 1. Beats with timestamps in `range` are used. Exact duplicates (same device, source, record key and
///    index in record) count once.
/// 2. Source precedence. A *usable* beat (finite interval within 300–2000 ms and none of
///    ``flaggedQuality`` or `outOfRange`) claims the span `[t − interval, t)` it closes. Sources rank band
///    history > live vendor stream > backup import > standard Heart Rate Service > demo. A beat is dropped
///    as an overlapping copy when the middle of its own span (its timestamp when its interval is not finite
///    and positive) lies inside a span claimed by a kept usable beat of a higher-ranked source; a beat that
///    is not usable is also dropped when that point lies inside a span claimed by a kept usable beat of any
///    other source. Copies of the same night from two streams therefore never interleave.
/// 3. The remaining beats are sorted by timestamp (ties: source rank, device ID, record key, index in
///    record, then the interval and the other fields, so the order never depends on the input order).
/// 4. A new segment starts when Δt to the previous beat is ≤ 0, exceeds the beat's own interval + 2000 ms
///    (dropout), or is less than half of the beat's own interval when that interval is plausible
///    (overlapping timestamps: the interval cannot fit since the previous beat), or when the source or
///    device changes. An implausible interval value never starts a segment by itself (rule A handles it).
/// 5. Each beat is classified in order: flagged (device/ingest flags) → rule A (outside 300–2000 ms) →
///    rule B (> 20 % from the median of the last ≤ 5 accepted beats of the segment, once ≥ 3 exist) →
///    accepted. Rejected beats are never used as references.
/// 6. Successive differences are formed only between two accepted adjacent beats of the same segment
///    whose timestamps fall in the same 5-min window (windows are aligned to `range.start`; a trailing
///    partial window is not analysed).
/// 7. A window is valid if ≥ 80 % of its beats are accepted, its accepted intervals sum to ≥ 180 s and it
///    has ≥ 100 pairs; its RMSSD = sqrt(mean(diff²)).
/// 8. Period RMSSD = median of valid-window RMSSDs; requires ≥ 6 valid windows. A median of 0 ms (no
///    beat-to-beat variation) is reported as low quality, never as a value.
///
/// Synchronous and pure: run it off the main actor for a night of beats.
public enum HRVAnalyzer {
    /// Flags that make a beat unusable regardless of its value (`unvalidatedField`: decoded from a field whose
    /// meaning is not yet validated for the firmware).
    public static let flaggedQuality: QualityFlags = [.deviceMarkedInvalid, .noSensorContact, .clockUnmapped, .unvalidatedField,
                                                      .nearClockDiscontinuity]
    /// Sensor named when the band provides no beat intervals.
    public static let sensorName = "beat-to-beat intervals"
    /// A beat with a plausible interval starts a new segment when the time since the previous beat is less than
    /// this fraction of that interval: the timestamps overlap, so the two beats are not adjacent heartbeats.
    public static let overlapFraction = 0.5

    enum Verdict: Equatable { case accepted, ruleA, ruleB, flagged }

    struct WindowAccumulator {
        var beats = 0
        var accepted = 0
        var acceptedMillis = 0.0
        var pairs = 0
        var sumOfSquares = 0.0
        var artifacts = HRVArtifactCounts()
    }

    /// Analyses one period, typically a confirmed sleep window.
    /// - Parameter beats: nil when the band/adapter does not provide beat intervals (→ `unsupportedSensor`);
    ///   an empty array means no data was recorded (→ `insufficientData`).
    public static func analyze(beats: [BeatInterval]?, range: TimeRange,
                               parameters p: HRVParameters = .default) -> HRVAnalysis {
        func notAnalysed(_ a: Availability, window: TimeRange?) -> HRVAnalysis {
            HRVAnalysis(range: range, rmssd: MetricCatalog.hrvRMSSD.unavailable(a, window: window),
                        lnRMSSD: MetricCatalog.hrvLnRMSSD.unavailable(a, window: window),
                        rawRMSSD: MetricCatalog.hrvRawRMSSD.unavailable(a, window: window),
                        totalBeats: 0, acceptedBeats: 0, acceptedFraction: nil, artifacts: HRVArtifactCounts(),
                        segmentCount: 0, validWindows: 0, totalWindows: 0, windows: [], parameters: p)
        }
        guard p.isValid else { return notAnalysed(.disabled(reason: "Invalid HRV parameters"), window: nil) }
        guard Sanity.isSane(range), !range.isEmpty else {
            return notAnalysed(.insufficientData(detail: "The analysis period is empty or invalid"), window: nil)
        }
        guard range.durationMillis <= p.maximumAnalysisMillis else {
            let a: Availability = beats == nil
                ? .unsupportedSensor(sensor: sensorName)
                : .lowQuality(detail: "The analysis period is longer than \(Fmt.duration(p.maximumAnalysisMillis))")
            return notAnalysed(a, window: range)
        }
        // Without a beat source the (empty) period is still analysed, so its window counts are real.
        return analyzed(beats: beats ?? [], range: range, parameters: p, missingSensor: beats == nil)
    }

    static func analyzed(beats: [BeatInterval], range: TimeRange, parameters p: HRVParameters,
                         missingSensor: Bool) -> HRVAnalysis {
        let spec = MetricCatalog.hrvRMSSD
        let lnSpec = MetricCatalog.hrvLnRMSSD
        let rawSpec = MetricCatalog.hrvRawRMSSD
        let totalWindows = Int(range.durationMillis / p.windowMillis)
        let prepared = prepare(beats, in: range)
        let sorted = prepared.beats
        let n = sorted.count

        // Segmentation and artifact classification.
        var verdicts = [Verdict](repeating: .accepted, count: n)
        var segmentOf = [Int](repeating: 0, count: n)
        var segment = -1
        var references: [Double] = []
        for i in 0..<n {
            let beat = sorted[i]
            if i == 0 || startsSegment(beat, after: sorted[i - 1], parameters: p) {
                segment += 1
                references.removeAll(keepingCapacity: true)
            }
            segmentOf[i] = segment
            let verdict = classify(beat, references: references, parameters: p)
            verdicts[i] = verdict
            if verdict == .accepted {
                references.append(beat.intervalMillis)
                if references.count > p.ruleBReferenceBeats {
                    references.removeFirst(references.count - p.ruleBReferenceBeats)
                }
            }
        }

        // Window accumulation.
        func windowIndex(_ t: EpochMillis) -> Int? {
            let w = Int((t - range.start) / p.windowMillis)
            return w < totalWindows ? w : nil
        }
        var acc = [WindowAccumulator](repeating: WindowAccumulator(), count: totalWindows)
        for i in 0..<n {
            guard let w = windowIndex(sorted[i].timestamp) else { continue }
            acc[w].beats += 1
            switch verdicts[i] {
            case .accepted:
                acc[w].accepted += 1
                acc[w].acceptedMillis += sorted[i].intervalMillis
            case .ruleA: acc[w].artifacts.ruleA += 1
            case .ruleB: acc[w].artifacts.ruleB += 1
            case .flagged: acc[w].artifacts.flagged += 1
            }
            if i > 0, verdicts[i] == .accepted, verdicts[i - 1] == .accepted, segmentOf[i] == segmentOf[i - 1],
               windowIndex(sorted[i - 1].timestamp) == w {
                let d = sorted[i].intervalMillis - sorted[i - 1].intervalMillis
                acc[w].pairs += 1
                acc[w].sumOfSquares += d * d
            }
        }

        // Window validity.
        var windows: [HRVWindow] = []
        windows.reserveCapacity(totalWindows)
        var validRMSSDs: [Double] = []
        var totalBeats = 0, acceptedBeats = 0
        var artifacts = HRVArtifactCounts()
        for (k, a) in acc.enumerated() {
            totalBeats += a.beats
            acceptedBeats += a.accepted
            artifacts.ruleA += a.artifacts.ruleA
            artifacts.ruleB += a.artifacts.ruleB
            artifacts.flagged += a.artifacts.flagged
            var reason: String?
            if a.beats == 0 {
                reason = "no beats"
            } else if !Threshold.meets(Double(a.accepted), of: Double(a.beats), fraction: p.windowMinimumAcceptedFraction) {
                reason = "\(Fmt.percent(Double(a.accepted) / Double(a.beats), decimals: 1)) of beats accepted; needs at least \(Fmt.percent(p.windowMinimumAcceptedFraction))"
            } else if a.acceptedMillis + 1e-6 < p.windowMinimumAcceptedMillis {
                reason = "accepted intervals sum to \(Fmt.number(a.acceptedMillis / 1_000, decimals: 1)) s; needs at least \(Fmt.number(p.windowMinimumAcceptedMillis / 1_000, decimals: 0)) s"
            } else if a.pairs < p.windowMinimumPairs {
                reason = "\(a.pairs) successive pairs; needs at least \(p.windowMinimumPairs)"
            }
            var windowRMSSD: Double?
            if reason == nil {
                let r = (a.sumOfSquares / Double(a.pairs)).squareRoot()
                if r.isFinite {
                    windowRMSSD = r
                    validRMSSDs.append(r)
                } else {
                    reason = "RMSSD is not finite"
                }
            }
            let start = range.start + Int64(k) * p.windowMillis
            windows.append(HRVWindow(range: TimeRange(start: start, end: start + p.windowMillis), beats: a.beats,
                                     acceptedBeats: a.accepted, acceptedIntervalMillis: a.acceptedMillis,
                                     successivePairs: a.pairs, rmssd: windowRMSSD.map { Stats.rounded($0, decimals: 1) },
                                     isValid: reason == nil, invalidReason: reason))
        }

        // Diagnostic raw RMSSD: every adjacent in-segment pair, no rejection, whole period.
        var rawSumOfSquares = 0.0
        var rawPairs = 0
        for i in stride(from: 1, to: n, by: 1) where segmentOf[i] == segmentOf[i - 1] {
            let a = sorted[i - 1].intervalMillis, b = sorted[i].intervalMillis
            guard a.isFinite, b.isFinite else { continue }
            rawSumOfSquares += (b - a) * (b - a)
            rawPairs += 1
        }

        let valid = validRMSSDs.count
        let coverage: Double? = missingSensor ? nil : (totalWindows > 0 ? Double(valid) / Double(totalWindows) : nil)
        let acceptedFraction: Double? = totalBeats > 0 ? Double(acceptedBeats) / Double(totalBeats) : nil
        let artifactRate = acceptedFraction.map { 1 - $0 } ?? 1
        let sourceNames = Set(sorted.map(\.source.description)).sorted().joined(separator: ", ")
        var inputs: [String: String] = [
            "validWindows": "\(valid) of \(totalWindows)",
            "acceptedBeats": "\(acceptedBeats) of \(totalBeats)" + (acceptedFraction.map { " (\(Fmt.percent($0, decimals: 1)))" } ?? ""),
            "artifactsRuleA": "\(artifacts.ruleA)",
            "artifactsRuleB": "\(artifacts.ruleB)",
            "artifactsFlagged": "\(artifacts.flagged)",
            "segments": "\(segment + 1)",
            "signal": "device-provided beat intervals (optical pulse intervals on a wrist band); never derived from heart rate",
        ]
        if !sourceNames.isEmpty { inputs["sources"] = sourceNames }
        if prepared.exactDuplicates > 0 {
            inputs["exactDuplicates"] = "\(prepared.exactDuplicates) duplicate records counted once"
        }
        if prepared.overlapping > 0 {
            inputs["overlappingSources"] = "\(prepared.overlapping) beats dropped where another source already covers the time"
        }

        let failure: Availability?
        var median: Double?
        if missingSensor {
            failure = .unsupportedSensor(sensor: sensorName)
        } else if n == 0 {
            failure = .insufficientData(detail: "No beat-interval data in this period")
        } else if totalWindows == 0 {
            failure = .insufficientData(detail: "The analysis period is shorter than one \(Fmt.duration(p.windowMillis)) window")
        } else if valid < p.minimumValidWindows {
            failure = .insufficientData(detail: "Needs at least \(p.minimumValidWindows) valid \(Fmt.duration(p.windowMillis)) windows; have \(valid) of \(totalWindows)")
        } else if let m = Stats.median(validRMSSDs), m > 0 {
            failure = nil
            median = m
        } else {
            failure = .lowQuality(detail: "Beat intervals show no beat-to-beat variation (RMSSD 0 ms), which suggests quantised or synthetic data")
        }

        let rmssd: MetricValue<Double>
        let lnRMSSD: MetricValue<Double>
        if let median {
            let confidence = Self.confidence(coverage: coverage ?? 0, artifactRate: artifactRate, parameters: p)
            inputs["artifactRate"] = Fmt.percent(artifactRate, decimals: 1)
            rmssd = spec.number(Stats.rounded(median, decimals: 1), coverage: coverage, confidence: confidence,
                                window: range, inputs: inputs)
            var lnInputs = inputs
            lnInputs["unit"] = "ln(ms)"
            lnInputs["rmssd"] = Fmt.number(median, decimals: 3) + " ms (unrounded period median)"
            lnRMSSD = lnSpec.number(Stats.rounded(log(median), decimals: 3), coverage: coverage, confidence: confidence,
                                    window: range, inputs: lnInputs)
        } else {
            let a = failure ?? .insufficientData(detail: "No value could be computed")
            rmssd = spec.unavailable(a, coverage: coverage, window: range, inputs: inputs)
            lnRMSSD = lnSpec.unavailable(a, coverage: coverage, window: range, inputs: inputs)
        }

        var rawInputs = ["diagnosticOnly": "true: no artifact rejection; for comparison with the filtered value only",
                         "pairs": "\(rawPairs)"]
        rawInputs["segments"] = "\(segment + 1)"
        let rawRMSSD: MetricValue<Double>
        if missingSensor {
            rawRMSSD = rawSpec.unavailable(.unsupportedSensor(sensor: sensorName), window: range, inputs: rawInputs)
        } else if rawPairs > 0 {
            rawRMSSD = rawSpec.number(Stats.rounded((rawSumOfSquares / Double(rawPairs)).squareRoot(), decimals: 1), coverage: nil,
                                      confidence: .low, window: range, inputs: rawInputs)
        } else {
            rawRMSSD = rawSpec.unavailable(.insufficientData(detail: "No adjacent beat pairs in this period"), window: range, inputs: rawInputs)
        }

        return HRVAnalysis(range: range, rmssd: rmssd, lnRMSSD: lnRMSSD, rawRMSSD: rawRMSSD, totalBeats: totalBeats,
                           acceptedBeats: acceptedBeats, acceptedFraction: acceptedFraction, artifacts: artifacts,
                           segmentCount: segment + 1, validWindows: valid, totalWindows: totalWindows, windows: windows,
                           parameters: p)
    }

    /// High when valid/total windows ≥ 70 % and artifact rate ≤ 5 %; moderate when ≥ 40 % and ≤ 15 %; otherwise low.
    static func confidence(coverage: Double, artifactRate: Double, parameters p: HRVParameters) -> Confidence {
        let eps = 1e-12
        if coverage + eps >= p.highConfidenceMinimumCoverage, artifactRate <= p.highConfidenceMaximumArtifactRate + eps {
            return .high
        }
        if coverage + eps >= p.moderateConfidenceMinimumCoverage, artifactRate <= p.moderateConfidenceMaximumArtifactRate + eps {
            return .moderate
        }
        return .low
    }

    // MARK: Segmentation and classification

    /// Step 4: whether `beat` cannot be differenced with `previous` (timing break, source or device change).
    static func startsSegment(_ beat: BeatInterval, after previous: BeatInterval, parameters p: HRVParameters) -> Bool {
        if beat.source != previous.source || beat.deviceID != previous.deviceID { return true }
        let dt = Double(beat.timestamp - previous.timestamp)
        let x = beat.intervalMillis
        if dt <= 0 { return true }
        if dt > (x.isFinite ? x : 0) + p.dropoutToleranceMillis { return true }
        if x.isFinite, BeatInterval.plausibleMillis.contains(x), dt < overlapFraction * x { return true }
        return false
    }

    /// Step 5: flagged → rule A → rule B → accepted.
    static func classify(_ beat: BeatInterval, references: [Double], parameters p: HRVParameters) -> Verdict {
        let x = beat.intervalMillis
        if !beat.quality.isDisjoint(with: flaggedQuality) { return .flagged }
        if !x.isFinite || !BeatInterval.plausibleMillis.contains(x) || beat.quality.contains(.outOfRange) { return .ruleA }
        if references.count >= p.ruleBMinimumReferences, let m = Stats.median(references), abs(x - m) > p.ruleBMaximumDeviation * m {
            return .ruleB
        }
        return .accepted
    }

    // MARK: Duplicates and source precedence

    struct Prepared {
        /// In-period beats after duplicate removal and source precedence, in canonical time order.
        var beats: [BeatInterval]
        var exactDuplicates: Int
        var overlapping: Int
    }

    /// Steps 1–3.
    static func prepare(_ beats: [BeatInterval], in range: TimeRange) -> Prepared {
        var byKey: [BeatKey: BeatInterval] = [:]
        var inRange = 0
        for b in beats where range.contains(b.timestamp) {
            inRange += 1
            let key = BeatKey(b)
            if let existing = byKey[key], !canonicalOrder(b, existing) { continue }
            byKey[key] = b
        }
        let (kept, overlapping) = applySourcePrecedence(Array(byKey.values))
        var sorted = kept
        sorted.sort(by: canonicalOrder)
        return Prepared(beats: sorted, exactDuplicates: inRange - byKey.count, overlapping: overlapping)
    }

    /// Identity of one interval in its record (the store's dedup key).
    struct BeatKey: Hashable {
        var deviceID: String
        var source: MeasurementSource
        var recordKey: Int64
        var indexInRecord: Int

        init(_ b: BeatInterval) {
            deviceID = b.deviceID
            source = b.source
            recordKey = b.recordKey
            indexInRecord = b.indexInRecord
        }
    }

    /// Step 2. Order-independent: each source rank only consults spans claimed by kept beats of better ranks.
    static func applySourcePrecedence(_ beats: [BeatInterval]) -> (kept: [BeatInterval], dropped: Int) {
        let ranks = MeasurementSource.allCases.map { HeartRateSeries.sourceRank($0) }
        var byRank = [[BeatInterval]](repeating: [], count: (ranks.max() ?? 0) + 1)
        for b in beats { byRank[HeartRateSeries.sourceRank(b.source)].append(b) }

        // First pass: a beat whose reference point lies in a span claimed by a better-ranked source is a copy.
        var claimedByBetter = ClaimedSpans()
        var claimsBySource: [MeasurementSource: ClaimedSpans] = [:]
        var kept: [BeatInterval] = []
        kept.reserveCapacity(beats.count)
        var dropped = 0
        for rankBeats in byRank where !rankBeats.isEmpty {
            var keptHere: [BeatInterval] = []
            for b in rankBeats {
                if claimedByBetter.contains(referencePoint(of: b)) { dropped += 1 } else { keptHere.append(b) }
            }
            var spansBySource: [MeasurementSource: [ClaimedSpans.Span]] = [:]
            for b in keptHere {
                if let span = claimedSpan(of: b) { spansBySource[b.source, default: []].append(span) }
            }
            for (source, spans) in spansBySource {
                claimsBySource[source, default: ClaimedSpans()].add(spans)
                claimedByBetter.add(spans)
            }
            kept += keptHere
        }

        // Second pass: an unusable beat is redundant where a usable beat of another source covers the time
        // (for example band history flagged unusable, with a usable live copy of the same beats).
        guard !claimsBySource.isEmpty else { return (kept, dropped) }
        var out: [BeatInterval] = []
        out.reserveCapacity(kept.count)
        for b in kept {
            if claimedSpan(of: b) == nil {
                let point = referencePoint(of: b)
                if claimsBySource.contains(where: { $0.key != b.source && $0.value.contains(point) }) {
                    dropped += 1
                    continue
                }
            }
            out.append(b)
        }
        return (out, dropped)
    }

    /// The span `[t − interval, t)` a usable beat claims, or nil for a beat that is not usable.
    static func claimedSpan(of b: BeatInterval) -> ClaimedSpans.Span? {
        let x = b.intervalMillis
        guard b.quality.isDisjoint(with: flaggedQuality), !b.quality.contains(.outOfRange),
              x.isFinite, BeatInterval.plausibleMillis.contains(x) else { return nil }
        return ClaimedSpans.Span(start: b.timestamp - Int64(x.rounded()), end: b.timestamp)
    }

    /// The middle of the span a beat closes (interval capped at 2000 ms), or its timestamp when the interval
    /// is not finite and positive.
    static func referencePoint(of b: BeatInterval) -> EpochMillis {
        let x = b.intervalMillis
        guard x.isFinite, x > 0 else { return b.timestamp }
        return b.timestamp - Int64((min(x, BeatInterval.plausibleMillis.upperBound) / 2).rounded(.down))
    }

    /// Disjoint, ascending half-open spans with O(log n) membership queries.
    struct ClaimedSpans {
        struct Span {
            var start: Int64
            var end: Int64
        }

        private var starts: [Int64] = []
        private var ends: [Int64] = []

        func contains(_ t: Int64) -> Bool {
            let i = Search.upperBound(starts, t) - 1
            return i >= 0 && t < ends[i]
        }

        mutating func add(_ spans: [Span]) {
            guard !spans.isEmpty else { return }
            var all = spans
            for i in starts.indices { all.append(Span(start: starts[i], end: ends[i])) }
            all.sort { $0.start < $1.start }
            var s: [Int64] = [], e: [Int64] = []
            s.reserveCapacity(all.count)
            e.reserveCapacity(all.count)
            for span in all where span.end > span.start {
                if let last = e.last, span.start <= last {
                    e[e.count - 1] = max(last, span.end)
                } else {
                    s.append(span.start)
                    e.append(span.end)
                }
            }
            starts = s
            ends = e
        }
    }

    /// Deterministic total order: time, then source rank, device, record key, index, interval (IEEE total
    /// order, so NaN cannot break sorting) and the remaining fields. Also picks the copy kept among exact duplicates.
    static func canonicalOrder(_ a: BeatInterval, _ b: BeatInterval) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
        let ra = HeartRateSeries.sourceRank(a.source), rb = HeartRateSeries.sourceRank(b.source)
        if ra != rb { return ra < rb }
        if a.deviceID != b.deviceID { return a.deviceID < b.deviceID }
        if a.recordKey != b.recordKey { return a.recordKey < b.recordKey }
        if a.indexInRecord != b.indexInRecord { return a.indexInRecord < b.indexInRecord }
        let ia = a.intervalMillis, ib = b.intervalMillis
        if ia.isTotallyOrdered(belowOrEqualTo: ib) != ib.isTotallyOrdered(belowOrEqualTo: ia) {
            return ia.isTotallyOrdered(belowOrEqualTo: ib)
        }
        if a.receivedAt != b.receivedAt { return a.receivedAt < b.receivedAt }
        if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue < b.quality.rawValue }
        let ba = a.batchID ?? .min, bb = b.batchID ?? .min
        if ba != bb { return ba < bb }
        return a.timingBasis.rawValue < b.timingBasis.rawValue
    }
}
