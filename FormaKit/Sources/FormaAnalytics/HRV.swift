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
    /// Rule B reference: the median of the last ≤ this many accepted intervals of the segment.
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
    /// Longer analysis periods are rejected as malformed, ms (24 h).
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

    var isValid: Bool {
        let fractions = [ruleBMaximumDeviation, windowMinimumAcceptedFraction, highConfidenceMinimumCoverage,
                         highConfidenceMaximumArtifactRate, moderateConfidenceMinimumCoverage, moderateConfidenceMaximumArtifactRate]
        return windowMillis >= 10_000 && maximumAnalysisMillis > 0 && maximumAnalysisMillis <= 7 * 24 * 3_600_000
            && dropoutToleranceMillis.isFinite && dropoutToleranceMillis >= 0
            && ruleBReferenceBeats >= 1 && ruleBMinimumReferences >= 1 && ruleBMinimumReferences <= ruleBReferenceBeats
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
    /// Flagged by the device or ingest: `deviceMarkedInvalid`, `noSensorContact` or `clockUnmapped`.
    public var flagged: Int

    public init(ruleA: Int = 0, ruleB: Int = 0, flagged: Int = 0) {
        self.ruleA = ruleA
        self.ruleB = ruleB
        self.flagged = flagged
    }

    public var total: Int { ruleA + ruleB + flagged }
}

/// One 5-minute analysis window.
public struct HRVWindow: Hashable, Sendable, Codable {
    public var range: TimeRange
    /// All beats whose timestamp lies in the window (accepted and rejected).
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
public struct HRVAnalysis: Hashable, Sendable, Codable {
    public var range: TimeRange
    /// Median of valid-window RMSSDs, ms, rounded to 0.1 (spec `forma.hrv.rmssd`).
    public var rmssd: MetricValue<Double>
    /// Natural log of the (unrounded) period RMSSD in ms, rounded to 0.001.
    public var lnRMSSD: MetricValue<Double>
    /// DIAGNOSTIC ONLY: RMSSD of all adjacent in-segment pairs with no artifact rejection, ms
    /// (spec `forma.hrv.rmssd.raw`). Never use it as a wellness value.
    public var rawRMSSD: MetricValue<Double>
    /// Beats in the analysed windows (beats in a trailing partial window are not counted).
    public var totalBeats: Int
    public var acceptedBeats: Int
    /// accepted / total beats; nil when there are no beats.
    public var acceptedFraction: Double?
    public var artifacts: HRVArtifactCounts
    /// Segments found among the beats of the analysis period.
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
/// 1. Beats with timestamps in `range` are sorted by timestamp (ties: source, record key, index).
/// 2. A new segment starts when Δt to the previous beat is negative or exceeds the beat's own interval
///    + 2000 ms (dropout), or when the source or device changes.
/// 3. Each beat is classified in order: flagged (device/ingest flags) → rule A (outside 300–2000 ms) →
///    rule B (> 20 % from the median of the last ≤ 5 accepted beats of the segment, once ≥ 3 exist) →
///    accepted. Rejected beats are never used as references.
/// 4. Successive differences are formed only between two accepted adjacent beats of the same segment
///    whose timestamps fall in the same 5-min window (windows are aligned to `range.start`; a trailing
///    partial window is not analysed).
/// 5. A window is valid if ≥ 80 % of its beats are accepted, its accepted intervals sum to ≥ 180 s and it
///    has ≥ 100 pairs; its RMSSD = sqrt(mean(diff²)).
/// 6. Period RMSSD = median of valid-window RMSSDs; requires ≥ 6 valid windows.
public enum HRVAnalyzer {
    /// Flags that make a beat unusable regardless of its value.
    public static let flaggedQuality: QualityFlags = [.deviceMarkedInvalid, .noSensorContact, .clockUnmapped]
    /// Sensor named when the band provides no beat intervals.
    public static let sensorName = "beat-to-beat intervals"

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
        let spec = MetricCatalog.hrvRMSSD
        let rawSpec = MetricCatalog.hrvRawRMSSD
        func unavailable(_ a: Availability, window: TimeRange?, inputs: [String: String] = [:]) -> HRVAnalysis {
            HRVAnalysis(range: range, rmssd: spec.unavailable(a, window: window, inputs: inputs),
                        lnRMSSD: spec.unavailable(a, window: window, inputs: inputs),
                        rawRMSSD: rawSpec.unavailable(a, window: window, inputs: inputs),
                        totalBeats: 0, acceptedBeats: 0, acceptedFraction: nil, artifacts: HRVArtifactCounts(),
                        segmentCount: 0, validWindows: 0, totalWindows: 0, windows: [], parameters: p)
        }
        guard p.isValid else { return unavailable(.disabled(reason: "Invalid HRV parameters"), window: nil) }
        guard Sanity.isSane(range), !range.isEmpty else {
            return unavailable(.insufficientData(detail: "The analysis period is empty or invalid"), window: nil)
        }
        guard let beats else { return unavailable(.unsupportedSensor(sensor: sensorName), window: range) }
        guard range.durationMillis <= p.maximumAnalysisMillis else {
            return unavailable(.lowQuality(detail: "The analysis period is longer than \(Fmt.duration(p.maximumAnalysisMillis))"), window: range)
        }
        let totalWindows = Int(range.durationMillis / p.windowMillis)
        var sorted = beats.filter { range.contains($0.timestamp) }
        sorted.sort(by: beatOrder)
        let n = sorted.count

        // Segmentation and artifact classification.
        var verdicts = [Verdict](repeating: .accepted, count: n)
        var segmentOf = [Int](repeating: 0, count: n)
        var segment = -1
        var references: [Double] = []
        for i in 0..<n {
            let beat = sorted[i]
            var startsSegment = i == 0
            if i > 0 {
                let previous = sorted[i - 1]
                let dt = Double(beat.timestamp - previous.timestamp)
                let expected = beat.intervalMillis.isFinite ? beat.intervalMillis : 0
                if dt < 0 || dt > expected + p.dropoutToleranceMillis
                    || beat.source != previous.source || beat.deviceID != previous.deviceID {
                    startsSegment = true
                }
            }
            if startsSegment {
                segment += 1
                references.removeAll(keepingCapacity: true)
            }
            segmentOf[i] = segment
            let x = beat.intervalMillis
            if !beat.quality.isDisjoint(with: flaggedQuality) {
                verdicts[i] = .flagged
            } else if !x.isFinite || !BeatInterval.plausibleMillis.contains(x) || beat.quality.contains(.outOfRange) {
                verdicts[i] = .ruleA
            } else if references.count >= p.ruleBMinimumReferences, let m = Stats.median(references),
                      abs(x - m) > p.ruleBMaximumDeviation * m {
                verdicts[i] = .ruleB
            } else {
                verdicts[i] = .accepted
                references.append(x)
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
        let coverage: Double? = totalWindows > 0 ? Double(valid) / Double(totalWindows) : nil
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
            "signal": "device-provided beat intervals (optical pulse intervals on WHOOP); never derived from heart rate",
        ]
        if !sourceNames.isEmpty { inputs["sources"] = sourceNames }

        let rmssd: MetricValue<Double>
        let lnRMSSD: MetricValue<Double>
        if n == 0 {
            let a = Availability.insufficientData(detail: "No beat-interval data in this period")
            rmssd = spec.unavailable(a, coverage: coverage, window: range, inputs: inputs)
            lnRMSSD = rmssd
        } else if totalWindows == 0 {
            let a = Availability.insufficientData(detail: "The analysis period is shorter than one \(Fmt.duration(p.windowMillis)) window")
            rmssd = spec.unavailable(a, coverage: coverage, window: range, inputs: inputs)
            lnRMSSD = rmssd
        } else if valid < p.minimumValidWindows {
            let a = Availability.insufficientData(detail: "Needs at least \(p.minimumValidWindows) valid \(Fmt.duration(p.windowMillis)) windows; have \(valid) of \(totalWindows)")
            rmssd = spec.unavailable(a, coverage: coverage, window: range, inputs: inputs)
            lnRMSSD = rmssd
        } else if let median = Stats.median(validRMSSDs), median > 0 {
            let confidence = Self.confidence(coverage: coverage ?? 0, artifactRate: artifactRate, parameters: p)
            inputs["artifactRate"] = Fmt.percent(artifactRate, decimals: 1)
            rmssd = spec.number(Stats.rounded(median, decimals: 1), coverage: coverage, confidence: confidence,
                                window: range, inputs: inputs)
            var lnInputs = inputs
            lnInputs["unit"] = "ln(ms)"
            lnRMSSD = spec.number(Stats.rounded(log(median), decimals: 3), coverage: coverage, confidence: confidence,
                                  window: range, inputs: lnInputs)
        } else {
            let a = Availability.lowQuality(detail: "Beat intervals show no beat-to-beat variation (RMSSD 0 ms), which suggests quantised or synthetic data")
            rmssd = spec.unavailable(a, coverage: coverage, window: range, inputs: inputs)
            lnRMSSD = rmssd
        }

        var rawInputs = ["diagnosticOnly": "true: no artifact rejection; for comparison with the filtered value only",
                         "pairs": "\(rawPairs)"]
        rawInputs["segments"] = "\(segment + 1)"
        let rawRMSSD: MetricValue<Double> = rawPairs > 0
            ? rawSpec.number(Stats.rounded((rawSumOfSquares / Double(rawPairs)).squareRoot(), decimals: 1), coverage: nil,
                             confidence: .low, window: range, inputs: rawInputs)
            : rawSpec.unavailable(.insufficientData(detail: "No adjacent beat pairs in this period"), window: range, inputs: rawInputs)

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

    /// Deterministic total order (IEEE total order for intervals, so NaN cannot break sorting).
    static func beatOrder(_ a: BeatInterval, _ b: BeatInterval) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
        if a.source != b.source { return a.source.rawValue < b.source.rawValue }
        if a.deviceID != b.deviceID { return a.deviceID < b.deviceID }
        if a.recordKey != b.recordKey { return a.recordKey < b.recordKey }
        if a.indexInRecord != b.indexInRecord { return a.indexInRecord < b.indexInRecord }
        return a.intervalMillis.isTotallyOrdered(belowOrEqualTo: b.intervalMillis)
            && !b.intervalMillis.isTotallyOrdered(belowOrEqualTo: a.intervalMillis)
    }
}
