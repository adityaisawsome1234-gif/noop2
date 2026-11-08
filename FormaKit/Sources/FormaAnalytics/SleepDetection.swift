import Foundation
import FormaCore

/// Parameters of the motion-based sleep candidate detector (defaults = spec `forma.sleep.candidate`).
///
/// Activity thresholds are in the unit of `MotionEpoch.activity` (ENMO-like, g). The defaults are
/// literature-informed placeholders that need calibration against the band's real accelerometer output.
public struct SleepDetectorParameters: Hashable, Sendable, Codable {
    /// Analysis epoch, ms (60 s). Motion epochs are re-binned onto this grid, weighted by sample count and overlap.
    public var epochMillis: Int64
    /// Centred rolling-median length, epochs (odd).
    public var rollingMedianEpochs: Int
    /// θ = clamp(multiplier × percentile(activity), lower, upper) over the epochs with data in the window.
    public var thresholdPercentile: Double
    public var thresholdMultiplier: Double
    public var thresholdLowerBound: Double
    public var thresholdUpperBound: Double
    /// Quiet runs separated by at most this much non-quiet or missing time are merged, ms (10 min).
    public var mergeGapMillis: Int64
    /// The main candidate is the longest merged run of at least this length, ms (3 h).
    public var minimumCandidateMillis: Int64
    /// Non-quiet runs (active epochs or epochs without motion data) of at least this many epochs inside the
    /// candidate are wake bouts, so unobserved stretches are never counted as sleep.
    public var minimumWakeBoutEpochs: Int
    /// Epochs with motion data / epochs inside the candidate (or confirmed window) must reach this fraction.
    public var minimumMotionCoverage: Double
    /// Heart rate supports a candidate only when usable HR covers at least this fraction of it.
    public var minimumHeartRateCoverage: Double
    /// …and at least this much HR is covered outside the candidate within the window, ms. The default, 0,
    /// needs only some usable heart rate outside the candidate (to take its median), as the spec states.
    public var minimumOutsideHeartRateMillis: Int64
    /// Local hour at which the detection window starts and ends (12 = noon-to-noon).
    public var windowStartHour: Int
    /// Confidence = clamp(motionWeight × coverage + continuityWeight × continuity + HR term, 0, 1);
    /// HR term = +support when HR supports, −contradiction when it contradicts, 0 when unavailable.
    public var confidenceMotionWeight: Double
    public var confidenceContinuityWeight: Double
    public var confidenceHeartRateSupport: Double
    public var confidenceHeartRateContradiction: Double
    /// Confirmed windows longer than this are rejected as malformed, ms (24 h).
    public var maximumConfirmedWindowMillis: Int64

    public init(epochMillis: Int64 = 60_000, rollingMedianEpochs: Int = 5, thresholdPercentile: Double = 0.10,
                thresholdMultiplier: Double = 2, thresholdLowerBound: Double = 0.010, thresholdUpperBound: Double = 0.040,
                mergeGapMillis: Int64 = 600_000, minimumCandidateMillis: Int64 = 3 * 3_600_000, minimumWakeBoutEpochs: Int = 2,
                minimumMotionCoverage: Double = 0.7, minimumHeartRateCoverage: Double = 0.5,
                minimumOutsideHeartRateMillis: Int64 = 0, windowStartHour: Int = 12,
                confidenceMotionWeight: Double = 0.5, confidenceContinuityWeight: Double = 0.2,
                confidenceHeartRateSupport: Double = 0.3, confidenceHeartRateContradiction: Double = 0.3,
                maximumConfirmedWindowMillis: Int64 = 24 * 3_600_000) {
        self.epochMillis = epochMillis
        self.rollingMedianEpochs = rollingMedianEpochs
        self.thresholdPercentile = thresholdPercentile
        self.thresholdMultiplier = thresholdMultiplier
        self.thresholdLowerBound = thresholdLowerBound
        self.thresholdUpperBound = thresholdUpperBound
        self.mergeGapMillis = mergeGapMillis
        self.minimumCandidateMillis = minimumCandidateMillis
        self.minimumWakeBoutEpochs = minimumWakeBoutEpochs
        self.minimumMotionCoverage = minimumMotionCoverage
        self.minimumHeartRateCoverage = minimumHeartRateCoverage
        self.minimumOutsideHeartRateMillis = minimumOutsideHeartRateMillis
        self.windowStartHour = windowStartHour
        self.confidenceMotionWeight = confidenceMotionWeight
        self.confidenceContinuityWeight = confidenceContinuityWeight
        self.confidenceHeartRateSupport = confidenceHeartRateSupport
        self.confidenceHeartRateContradiction = confidenceHeartRateContradiction
        self.maximumConfirmedWindowMillis = maximumConfirmedWindowMillis
    }

    public static let `default` = SleepDetectorParameters()

    var isValid: Bool {
        let finite = [thresholdPercentile, thresholdMultiplier, thresholdLowerBound, thresholdUpperBound, minimumMotionCoverage,
                      minimumHeartRateCoverage, confidenceMotionWeight, confidenceContinuityWeight,
                      confidenceHeartRateSupport, confidenceHeartRateContradiction].allSatisfy(\.isFinite)
        return finite && epochMillis >= 1_000 && epochMillis <= 3_600_000
            && rollingMedianEpochs >= 1 && rollingMedianEpochs % 2 == 1 && rollingMedianEpochs <= 61
            && (0...1).contains(thresholdPercentile) && thresholdMultiplier > 0
            && thresholdLowerBound >= 0 && thresholdLowerBound <= thresholdUpperBound
            && mergeGapMillis >= 0 && minimumCandidateMillis > 0 && minimumWakeBoutEpochs >= 1
            && (0...1).contains(minimumMotionCoverage) && (0...1).contains(minimumHeartRateCoverage)
            && minimumOutsideHeartRateMillis >= 0 && (0...23).contains(windowStartHour)
            && maximumConfirmedWindowMillis > 0 && maximumConfirmedWindowMillis <= 7 * 24 * 3_600_000
    }
}

/// Whether heart rate agrees that a candidate is sleep.
public enum HeartRateSupport: Hashable, Sendable, Codable {
    /// Time-weighted mean HR inside the candidate is below the median of the window's samples outside it.
    case supports(insideMeanBPM: Double, outsideMedianBPM: Double)
    /// Mean HR inside the candidate is not below the outside median.
    case contradicts(insideMeanBPM: Double, outsideMedianBPM: Double)
    /// Not enough heart rate to compare (the reason says what is missing).
    case unavailable(reason: String)
}

/// A proposed sleep period. It is only a candidate until the user confirms it; no sleep stages.
public struct SleepCandidate: Hashable, Sendable, Codable {
    /// From the start of the first quiet epoch to the end of the last quiet epoch of the merged run.
    public var range: TimeRange
    /// Non-quiet runs of ≥ 2 epochs inside the candidate: active epochs and epochs without motion data
    /// alike, so time that was not observed is never counted as sleep (the inputs state how much of the
    /// wake time had no motion data). A single non-quiet epoch between quiet ones is not a bout.
    public var wakeBouts: [TimeRange]
    /// Candidate length − wake bouts, ms.
    public var sleepDurationEstimateMillis: Int64
    /// Sum of wake bouts, ms.
    public var wakeAfterSleepOnsetMillis: Int64
    /// 1 − WASO / length (0…1).
    public var continuity: Double
    /// Detector confidence 0…1 (see ``SleepDetectorParameters``), rounded to 0.01.
    public var confidence: Double
    /// Epochs with motion data / epochs inside the candidate.
    public var coverage: Double
    public var heartRateSupport: HeartRateSupport
    /// The activity threshold θ used, in `MotionEpoch.activity` units.
    public var activityThreshold: Double
    public var parameters: SleepDetectorParameters

    public init(range: TimeRange, wakeBouts: [TimeRange], sleepDurationEstimateMillis: Int64, wakeAfterSleepOnsetMillis: Int64,
                continuity: Double, confidence: Double, coverage: Double, heartRateSupport: HeartRateSupport,
                activityThreshold: Double, parameters: SleepDetectorParameters) {
        self.range = range
        self.wakeBouts = wakeBouts
        self.sleepDurationEstimateMillis = sleepDurationEstimateMillis
        self.wakeAfterSleepOnsetMillis = wakeAfterSleepOnsetMillis
        self.continuity = continuity
        self.confidence = confidence
        self.coverage = coverage
        self.heartRateSupport = heartRateSupport
        self.activityThreshold = activityThreshold
        self.parameters = parameters
    }
}

/// Proposes the main sleep candidate of a night from motion (accelerometer) data.
///
/// Sleep is never inferred from heart rate alone: without motion data the result is
/// `unsupportedSensor("motion (accelerometer)")`. Heart rate can only raise or lower confidence.
public enum SleepDetector {
    /// Sensor named in `unsupportedSensor` when no motion input exists.
    public static let motionSensorName = "motion (accelerometer)"
    /// Motion epochs carrying any of these flags are treated as missing data (an off-wrist band lying
    /// still would otherwise look like sleep; an unvalidated field is never used).
    public static let excludedMotionFlags: QualityFlags = [.deviceMarkedInvalid, .noSensorContact, .clockUnmapped, .outOfRange,
                                                           .unvalidatedField, .nearClockDiscontinuity]

    /// The detection window for the night that ends on the morning of `day` (a Gregorian date; only
    /// `calendar`'s time zone is used): `[day−1 at windowStartHour, day at windowStartHour)` local time
    /// (23 or 25 h across DST changes).
    public static func window(nightEndingOn day: LocalDay, calendar: Calendar,
                              parameters p: SleepDetectorParameters = .default) -> TimeRange? {
        guard (0...23).contains(p.windowStartHour), let previous = DayMath.day(day, offsetBy: -1, calendar: calendar),
              let start = DayMath.time(hour: p.windowStartHour, on: previous, calendar: calendar),
              let end = DayMath.time(hour: p.windowStartHour, on: day, calendar: calendar),
              end > start, end - start <= 26 * 3_600_000
        else { return nil }
        return TimeRange(start: start, end: end)
    }

    /// Detects the main sleep candidate of the night ending on the morning of `day`. The result's `window`
    /// is the noon-to-noon window and its `coverage` the share of that window's epochs with motion data;
    /// `SleepCandidate.coverage` is the share inside the candidate (the 70 % gate).
    /// - Parameters:
    ///   - motion: nil when the band/adapter provides no motion data (→ `unsupportedSensor`); an empty
    ///     array or no usable epoch in the window → `insufficientData`.
    ///   - heartRate: optional; used only to adjust confidence.
    public static func detect(nightEndingOn day: LocalDay, calendar: Calendar, motion: [MotionEpoch]?,
                              heartRate: [HeartRateSample]? = nil,
                              parameters p: SleepDetectorParameters = .default) -> MetricValue<SleepCandidate> {
        let spec = MetricCatalog.sleepCandidate
        guard p.isValid else { return spec.unavailable(.disabled(reason: "Invalid sleep detector parameters"), window: nil) }
        let window = Self.window(nightEndingOn: day, calendar: calendar, parameters: p)
        guard let motion else { return spec.unavailable(.unsupportedSensor(sensor: motionSensorName), window: window) }
        guard let window else { return spec.unavailable(.insufficientData(detail: "Invalid day"), window: nil) }

        let grid = MotionGrid(range: window, epochMillis: p.epochMillis, motion: motion)
        guard let classification = MotionClassification(grid: grid, parameters: p) else {
            return spec.unavailable(.insufficientData(detail: "No motion (accelerometer) data in this window"), window: window)
        }
        let states = classification.states
        let windowCoverage = Double(classification.epochsWithData) / Double(grid.count)
        var inputs = ["activityThreshold": Fmt.number(classification.threshold, decimals: 4),
                      "windowMotionCoverage": Fmt.percent(windowCoverage),
                      "epochs": "\(grid.count) × \(Fmt.duration(p.epochMillis))"]

        let mergeGapEpochs = Int(p.mergeGapMillis / p.epochMillis)
        var best: EpochRun?
        var bestLength: Int64 = 0
        for run in MotionClassification.mergedQuietRuns(states, mergeGapEpochs: mergeGapEpochs) {
            let length = grid.range(ofEpochs: run).durationMillis
            if length > bestLength {
                best = run
                bestLength = length
            }
        }
        guard let candidate = best, bestLength >= p.minimumCandidateMillis else {
            inputs["longestQuietPeriod"] = Fmt.duration(bestLength)
            let longest = bestLength > 0 ? "; longest was \(Fmt.duration(bestLength))" : ""
            return spec.unavailable(.insufficientData(detail: "No quiet period of at least \(Fmt.duration(p.minimumCandidateMillis)) in this window\(longest)"),
                                    coverage: windowCoverage, window: window, inputs: inputs)
        }
        let candidateRange = grid.range(ofEpochs: candidate)
        let withData = states[candidate.first...candidate.last].filter { $0 != .missing }.count
        let coverage = Double(withData) / Double(candidate.count)
        inputs["candidateMotionCoverage"] = Fmt.percent(coverage)
        guard Threshold.meets(Double(withData), of: Double(candidate.count), fraction: p.minimumMotionCoverage) else {
            return spec.unavailable(.lowQuality(detail: "Motion data covers \(Fmt.percent(coverage, decimals: 1)) of the candidate; at least \(Fmt.percent(p.minimumMotionCoverage)) is needed"),
                                    coverage: windowCoverage, window: window, inputs: inputs)
        }
        let boutRuns = MotionClassification.wakeBouts(states, within: candidate, minimumEpochs: p.minimumWakeBoutEpochs)
        let bouts = boutRuns.map { grid.range(ofEpochs: $0) }
        let waso = bouts.reduce(Int64(0)) { $0 + $1.durationMillis }
        let length = candidateRange.durationMillis
        let continuity = 1 - Double(waso) / Double(length)
        let support = heartRateSupport(candidate: candidateRange, window: window, heartRate: heartRate, parameters: p)
        let score = confidenceScore(coverage: coverage, continuity: continuity, support: support, parameters: p)
        inputs["wakeBouts"] = describeWake(count: bouts.count, wakeMillis: waso,
                                           unobservedMillis: grid.missingMillis(in: boutRuns, states: states))
        inputs["heartRateSupport"] = describe(support)
        inputs["status"] = "candidate: shown for confirmation, not counted until confirmed"
        let result = SleepCandidate(range: candidateRange, wakeBouts: bouts, sleepDurationEstimateMillis: length - waso,
                                    wakeAfterSleepOnsetMillis: waso, continuity: continuity, confidence: score,
                                    coverage: coverage, heartRateSupport: support,
                                    activityThreshold: classification.threshold, parameters: p)
        return spec.available(result, coverage: windowCoverage, confidence: confidenceLabel(score), window: window, inputs: inputs)
    }

    /// ≥ 0.75 high, ≥ 0.5 moderate, otherwise low.
    public static func confidenceLabel(_ score: Double) -> Confidence {
        if score >= 0.75 { return .high }
        if score >= 0.5 { return .moderate }
        return .low
    }

    static func confidenceScore(coverage: Double, continuity: Double, support: HeartRateSupport,
                                parameters p: SleepDetectorParameters) -> Double {
        let hr: Double
        switch support {
        case .supports: hr = p.confidenceHeartRateSupport
        case .contradicts: hr = -p.confidenceHeartRateContradiction
        case .unavailable: hr = 0
        }
        let raw = p.confidenceMotionWeight * coverage + p.confidenceContinuityWeight * continuity + hr
        return Stats.rounded(Stats.clamp(raw, 0, 1), decimals: 2)
    }

    static func heartRateSupport(candidate: TimeRange, window: TimeRange, heartRate: [HeartRateSample]?,
                                 parameters p: SleepDetectorParameters) -> HeartRateSupport {
        guard let heartRate else { return .unavailable(reason: "No heart-rate data") }
        let series = HeartRateSeries(heartRate)
        let coverage = series.coverage(in: candidate) ?? 0
        guard Threshold.meets(coverage, of: 1, fraction: p.minimumHeartRateCoverage),
              let inside = series.timeWeightedMean(in: candidate) else {
            return .unavailable(reason: "Heart rate covers \(Fmt.percent(coverage, decimals: 1)) of the candidate; at least \(Fmt.percent(p.minimumHeartRateCoverage)) is needed")
        }
        let outsideCovered = series.coveredMillis(in: window) - series.coveredMillis(in: candidate)
        let outside = series.samples(in: window).filter { !candidate.contains($0.timestamp) }.map { Double($0.bpm) }
        guard outsideCovered >= p.minimumOutsideHeartRateMillis, let median = Stats.median(outside) else {
            return .unavailable(reason: p.minimumOutsideHeartRateMillis > 0
                ? "Less than \(Fmt.duration(p.minimumOutsideHeartRateMillis)) of heart rate outside the candidate to compare with"
                : "No usable heart rate outside the candidate in this window to compare with")
        }
        let insideRounded = Stats.rounded(inside, decimals: 1)
        let medianRounded = Stats.rounded(median, decimals: 1)
        return inside < median
            ? .supports(insideMeanBPM: insideRounded, outsideMedianBPM: medianRounded)
            : .contradicts(insideMeanBPM: insideRounded, outsideMedianBPM: medianRounded)
    }

    static func describe(_ support: HeartRateSupport) -> String {
        switch support {
        case let .supports(i, o): return "supports: mean \(Fmt.bpm(i)) inside vs median \(Fmt.bpm(o)) outside"
        case let .contradicts(i, o): return "does not support: mean \(Fmt.bpm(i)) inside vs median \(Fmt.bpm(o)) outside"
        case let .unavailable(reason): return "not used: \(reason)"
        }
    }

    /// "2 (14 min, of which 6 min without motion data)".
    static func describeWake(count: Int, wakeMillis: Int64, unobservedMillis: Int64) -> String {
        let unobserved = unobservedMillis > 0 ? ", of which \(Fmt.duration(unobservedMillis)) without motion data" : ""
        return "\(count) (\(Fmt.duration(wakeMillis))\(unobserved))"
    }
}

/// Summary of a sleep window the user entered or confirmed (spec `forma.sleep.summary`). No sleep stages.
public struct SleepSummary: Hashable, Sendable, Codable {
    public var window: TimeRange
    /// Window length (time in bed), ms.
    public var timeInBed: MetricValue<Int64>
    /// Non-quiet runs of ≥ 2 epochs inside the window (active or without motion data, including before sleep
    /// onset), so unobserved time is never counted as sleep; nil without usable motion.
    public var wakeBouts: [TimeRange]?
    /// Sum of wake bouts, ms (motion only).
    public var wakeDuration: MetricValue<Int64>
    /// Time in bed − wake, ms (motion only).
    public var sleepDurationEstimate: MetricValue<Int64>
    /// 1 − wake / time in bed, a fraction 0…1 (motion only; spec `forma.sleep.continuity`).
    public var continuity: MetricValue<Double>
    /// Time-weighted mean heart rate inside the window, bpm (needs ≥ 50 % HR coverage; spec `forma.sleep.heartrate`).
    public var meanHeartRate: MetricValue<Double>
    /// Epochs with motion data / epochs in the window.
    public var motionCoverage: Double?
    /// Covered HR / window length.
    public var heartRateCoverage: Double?

    public init(window: TimeRange, timeInBed: MetricValue<Int64>, wakeBouts: [TimeRange]?, wakeDuration: MetricValue<Int64>,
                sleepDurationEstimate: MetricValue<Int64>, continuity: MetricValue<Double>, meanHeartRate: MetricValue<Double>,
                motionCoverage: Double?, heartRateCoverage: Double?) {
        self.window = window
        self.timeInBed = timeInBed
        self.wakeBouts = wakeBouts
        self.wakeDuration = wakeDuration
        self.sleepDurationEstimate = sleepDurationEstimate
        self.continuity = continuity
        self.meanHeartRate = meanHeartRate
        self.motionCoverage = motionCoverage
        self.heartRateCoverage = heartRateCoverage
    }

    /// Duration = window length (time in bed, confidence high: the user confirmed it). Wake, sleep
    /// estimate and continuity only when motion exists: epochs are classified as in ``SleepDetector``
    /// with θ computed over the window's own epochs, and wake = non-quiet runs (active or without motion
    /// data) of ≥ 2 epochs; motion coverage < 70 % → `lowQuality`. Motion-only wake detection misses quiet
    /// wakefulness, so their confidence is capped at `.moderate`.
    public static func fromConfirmedWindow(_ window: TimeRange, motion: [MotionEpoch]?, heartRate: [HeartRateSample]? = nil,
                                           parameters p: SleepDetectorParameters = .default) -> SleepSummary {
        let spec = MetricCatalog.sleepSummary
        let continuitySpec = MetricCatalog.sleepContinuity
        let heartRateSpec = MetricCatalog.sleepHeartRate
        func allUnavailable(_ a: Availability, window w: TimeRange?) -> SleepSummary {
            SleepSummary(window: window, timeInBed: spec.unavailable(a, window: w), wakeBouts: nil,
                         wakeDuration: spec.unavailable(a, window: w), sleepDurationEstimate: spec.unavailable(a, window: w),
                         continuity: continuitySpec.unavailable(a, window: w), meanHeartRate: heartRateSpec.unavailable(a, window: w),
                         motionCoverage: nil, heartRateCoverage: nil)
        }
        guard p.isValid else { return allUnavailable(.disabled(reason: "Invalid sleep parameters"), window: nil) }
        guard Sanity.isSane(window), !window.isEmpty else {
            return allUnavailable(.insufficientData(detail: "The sleep window is empty or invalid"), window: nil)
        }
        guard window.durationMillis <= p.maximumConfirmedWindowMillis else {
            return allUnavailable(.lowQuality(detail: "The sleep window is longer than \(Fmt.duration(p.maximumConfirmedWindowMillis))"), window: window)
        }
        let tib = window.durationMillis
        let timeInBed: MetricValue<Int64> = spec.available(tib, coverage: nil, confidence: .high, window: window,
                                                           inputs: ["source": "confirmed sleep window (time in bed)"])

        // Heart rate.
        var heartRateCoverage: Double?
        let meanHeartRate: MetricValue<Double>
        if let heartRate {
            let series = HeartRateSeries(heartRate)
            let coverage = series.coverage(in: window) ?? 0
            heartRateCoverage = coverage
            let inputs = ["coverage": Fmt.percent(coverage), "minimumCoverage": Fmt.percent(p.minimumHeartRateCoverage)]
            if Threshold.meets(coverage, of: 1, fraction: p.minimumHeartRateCoverage), let mean = series.timeWeightedMean(in: window) {
                meanHeartRate = heartRateSpec.number(Stats.rounded(mean, decimals: 1), coverage: coverage,
                                                     confidence: .forAvailable(coverage: coverage), window: window, inputs: inputs)
            } else {
                meanHeartRate = heartRateSpec.unavailable(.insufficientData(detail: "Heart rate covers \(Fmt.percent(coverage, decimals: 1)) of this window; at least \(Fmt.percent(p.minimumHeartRateCoverage)) is needed"),
                                                          coverage: coverage, window: window, inputs: inputs)
            }
        } else {
            meanHeartRate = heartRateSpec.unavailable(.insufficientData(detail: "No heart-rate data"), window: window)
        }

        // Motion.
        func motionUnavailable(_ a: Availability, coverage: Double? = nil, inputs: [String: String] = [:]) -> SleepSummary {
            SleepSummary(window: window, timeInBed: timeInBed, wakeBouts: nil,
                         wakeDuration: spec.unavailable(a, coverage: coverage, window: window, inputs: inputs),
                         sleepDurationEstimate: spec.unavailable(a, coverage: coverage, window: window, inputs: inputs),
                         continuity: continuitySpec.unavailable(a, coverage: coverage, window: window, inputs: inputs),
                         meanHeartRate: meanHeartRate, motionCoverage: coverage, heartRateCoverage: heartRateCoverage)
        }
        guard let motion else { return motionUnavailable(.unsupportedSensor(sensor: SleepDetector.motionSensorName)) }
        let grid = MotionGrid(range: window, epochMillis: p.epochMillis, motion: motion)
        guard let classification = MotionClassification(grid: grid, parameters: p) else {
            return motionUnavailable(.insufficientData(detail: "No motion (accelerometer) data in this window"), coverage: 0)
        }
        let coverage = Double(classification.epochsWithData) / Double(grid.count)
        var inputs = ["motionCoverage": Fmt.percent(coverage), "activityThreshold": Fmt.number(classification.threshold, decimals: 4)]
        guard Threshold.meets(Double(classification.epochsWithData), of: Double(grid.count), fraction: p.minimumMotionCoverage) else {
            return motionUnavailable(.lowQuality(detail: "Motion data covers \(Fmt.percent(coverage, decimals: 1)) of this window; at least \(Fmt.percent(p.minimumMotionCoverage)) is needed"),
                                     coverage: coverage, inputs: inputs)
        }
        let all = EpochRun(first: 0, last: grid.count - 1)
        let boutRuns = MotionClassification.wakeBouts(classification.states, within: all, minimumEpochs: p.minimumWakeBoutEpochs)
        let bouts = boutRuns.map { grid.range(ofEpochs: $0) }
        let wake = bouts.reduce(Int64(0)) { $0 + $1.durationMillis }
        inputs["wakeBouts"] = SleepDetector.describeWake(count: bouts.count, wakeMillis: wake,
                                                         unobservedMillis: grid.missingMillis(in: boutRuns, states: classification.states))
        let confidence = min(Confidence.forAvailable(coverage: coverage), .moderate)
        return SleepSummary(window: window, timeInBed: timeInBed, wakeBouts: bouts,
                            wakeDuration: spec.available(wake, coverage: coverage, confidence: confidence, window: window, inputs: inputs),
                            sleepDurationEstimate: spec.available(tib - wake, coverage: coverage, confidence: confidence,
                                                                  window: window, inputs: inputs),
                            continuity: continuitySpec.number(1 - Double(wake) / Double(tib), coverage: coverage,
                                                              confidence: confidence, window: window, inputs: inputs),
                            meanHeartRate: meanHeartRate, motionCoverage: coverage, heartRateCoverage: heartRateCoverage)
    }
}

// MARK: - Motion internals

/// Inclusive run of epoch indices.
struct EpochRun: Hashable {
    var first: Int
    var last: Int
    var count: Int { last - first + 1 }
}

/// Motion re-binned onto a fixed epoch grid aligned to the window start (the last epoch may be partial).
struct MotionGrid {
    let window: TimeRange
    let epochMillis: Int64
    let count: Int
    private(set) var weight: [Double]
    private(set) var weightedActivity: [Double]

    init(range: TimeRange, epochMillis e: Int64, motion: [MotionEpoch]) {
        window = range
        epochMillis = e
        let duration = range.durationMillis
        count = Int((duration + e - 1) / e)
        weight = [Double](repeating: 0, count: count)
        weightedActivity = [Double](repeating: 0, count: count)
        guard count > 0 else { return }
        for m in motion {
            guard m.sampleCount > 0, m.activity.isFinite, m.activity >= 0,
                  m.quality.isDisjoint(with: SleepDetector.excludedMotionFlags), Sanity.isSane(m.timestamp)
            else { continue }
            let length = min(max(m.epochMillis, 1), 3_600_000)
            let mStart = m.timestamp
            let mEnd = m.timestamp + length
            guard mEnd > range.start, mStart < range.end else { continue }
            let firstIndex = Int(IntMath.floorDiv(max(mStart, range.start) - range.start, e))
            let lastIndex = min(count - 1, Int(IntMath.floorDiv(min(mEnd, range.end) - 1 - range.start, e)))
            guard firstIndex <= lastIndex else { continue }
            for g in firstIndex...lastIndex {
                let r = epochRange(g)
                let overlap = min(mEnd, r.end) - max(mStart, r.start)
                guard overlap > 0 else { continue }
                let w = Double(m.sampleCount) * Double(overlap) / Double(length)
                weight[g] += w
                weightedActivity[g] += w * m.activity
            }
        }
    }

    /// Sample-weighted mean activity of epoch `i`, or nil when it has no motion data.
    func activity(_ i: Int) -> Double? {
        weight[i] > 0 ? weightedActivity[i] / weight[i] : nil
    }

    func epochRange(_ i: Int) -> TimeRange {
        let start = window.start + Int64(i) * epochMillis
        return TimeRange(start: start, end: min(start + epochMillis, window.end))
    }

    func range(ofEpochs run: EpochRun) -> TimeRange {
        TimeRange(start: epochRange(run.first).start, end: epochRange(run.last).end)
    }

    /// Time covered by epochs without motion data inside `runs`, ms.
    func missingMillis(in runs: [EpochRun], states: [EpochState]) -> Int64 {
        var total: Int64 = 0
        for run in runs where run.first >= 0 && run.last < states.count && run.first <= run.last {
            for i in run.first...run.last where states[i] == .missing {
                total += epochRange(i).durationMillis
            }
        }
        return total
    }
}

enum EpochState: Equatable { case quiet, active, missing }

/// Quiet/active classification: quiet when the centred rolling median of activity is below θ.
struct MotionClassification {
    let threshold: Double
    let states: [EpochState]
    let epochsWithData: Int

    /// Nil when no epoch in the grid has motion data.
    init?(grid: MotionGrid, parameters p: SleepDetectorParameters) {
        let activity = (0..<grid.count).map { grid.activity($0) }
        let present = activity.compactMap { $0 }
        guard let percentile = Stats.percentile(present, p.thresholdPercentile) else { return nil }
        let theta = Stats.clamp(p.thresholdMultiplier * percentile, p.thresholdLowerBound, p.thresholdUpperBound)
        let half = p.rollingMedianEpochs / 2
        var states = [EpochState](repeating: .missing, count: grid.count)
        for i in 0..<grid.count where activity[i] != nil {
            var neighbourhood: [Double] = []
            for j in max(0, i - half)...min(grid.count - 1, i + half) {
                if let a = activity[j] { neighbourhood.append(a) }
            }
            if let m = Stats.median(neighbourhood) { states[i] = m < theta ? .quiet : .active }
        }
        threshold = theta
        self.states = states
        epochsWithData = present.count
    }

    /// Maximal runs of epochs matching `predicate` inside `bounds`.
    static func runs(in states: [EpochState], within bounds: EpochRun, where predicate: (EpochState) -> Bool) -> [EpochRun] {
        var out: [EpochRun] = []
        guard bounds.first >= 0, bounds.last < states.count, bounds.first <= bounds.last else { return out }
        var start: Int?
        for i in bounds.first...bounds.last {
            if predicate(states[i]) {
                if start == nil { start = i }
            } else if let s = start {
                out.append(EpochRun(first: s, last: i - 1))
                start = nil
            }
        }
        if let s = start { out.append(EpochRun(first: s, last: bounds.last)) }
        return out
    }

    /// Quiet runs merged across gaps of at most `mergeGapEpochs` non-quiet (active or missing) epochs.
    static func mergedQuietRuns(_ states: [EpochState], mergeGapEpochs: Int) -> [EpochRun] {
        guard !states.isEmpty else { return [] }
        var merged: [EpochRun] = []
        for run in runs(in: states, within: EpochRun(first: 0, last: states.count - 1), where: { $0 == .quiet }) {
            if let last = merged.last, run.first - last.last - 1 <= mergeGapEpochs {
                merged[merged.count - 1].last = run.last
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// Wake bouts: maximal non-quiet runs (active epochs and epochs without motion data alike) of at least
    /// `minimumEpochs` inside `bounds`. Missing data is never counted as sleep.
    static func wakeBouts(_ states: [EpochState], within bounds: EpochRun, minimumEpochs: Int) -> [EpochRun] {
        runs(in: states, within: bounds, where: { $0 != .quiet }).filter { $0.count >= minimumEpochs }
    }
}
