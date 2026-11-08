import Foundation
import FormaCore

/// Parameters of a personal baseline (defaults = spec `forma.baseline`).
public struct BaselineParameters: Hashable, Sendable, Codable {
    /// Calendar days before the target day that form the baseline (the target day is excluded).
    public var windowDays: Int
    /// Retained values required; fewer → `calibrating(have:need:unit:)`.
    public var minimumDays: Int
    /// Values with |x − median| > multiplier × scale × MAD are excluded (only when MAD > 0).
    public var outlierMADMultiplier: Double
    /// Consistency constant making MAD estimate the SD of normal data.
    public var madScale: Double
    /// Unit word used in the calibration message ("days", "nights").
    public var unit: String

    public init(windowDays: Int = 28, minimumDays: Int = 14, outlierMADMultiplier: Double = 3,
                madScale: Double = 1.4826, unit: String = "days") {
        self.windowDays = windowDays
        self.minimumDays = minimumDays
        self.outlierMADMultiplier = outlierMADMultiplier
        self.madScale = madScale
        self.unit = unit
    }

    public static let `default` = BaselineParameters()

    var isValid: Bool {
        (1...366).contains(windowDays) && minimumDays >= 1 && minimumDays <= windowDays
            && outlierMADMultiplier.isFinite && outlierMADMultiplier > 0 && madScale.isFinite && madScale > 0
    }
}

/// Robust baseline statistics.
public struct BaselineStatistics: Hashable, Sendable, Codable {
    /// Mean of the retained values.
    public var mean: Double
    /// Sample SD (n − 1) of the retained values; nil when fewer than two remain.
    public var standardDeviation: Double?
    /// Retained values.
    public var n: Int
    /// Values excluded as outliers.
    public var excluded: Int
    /// Median and unscaled MAD of all eligible values (before exclusion).
    public var median: Double
    public var medianAbsoluteDeviation: Double

    public init(mean: Double, standardDeviation: Double?, n: Int, excluded: Int, median: Double, medianAbsoluteDeviation: Double) {
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.n = n
        self.excluded = excluded
        self.median = median
        self.medianAbsoluteDeviation = medianAbsoluteDeviation
    }
}

/// Personal baselines from the previous N days.
public enum BaselineCalculator {
    /// Baseline for `targetDay` from the `windowDays` calendar days before it (the target day itself is
    /// never used; days are Gregorian dates in `calendar`'s time zone). Non-finite values and explicit nils
    /// count as missing. Outliers with |x − median| > 3 × 1.4826 × MAD are excluded when MAD > 0; with
    /// MAD = 0 nothing is excluded. Fewer than `minimumDays` retained values →
    /// `calibrating(have: n, need: minimumDays, unit:)`, with `inputs["excludedOutliers"]` saying how many
    /// eligible values were excluded. Coverage = eligible days / window days; confidence follows coverage.
    public static func baseline(values: [LocalDay: Double?], targetDay: LocalDay, calendar: Calendar,
                                parameters p: BaselineParameters = .default) -> MetricValue<BaselineStatistics> {
        let spec = MetricCatalog.baseline
        var inputs = ["windowDays": "\(p.windowDays) days before the target day (target day excluded)",
                      "minimumDays": "\(p.minimumDays) \(p.unit)"]
        guard p.isValid else {
            return spec.unavailable(.disabled(reason: "Invalid baseline parameters"), window: nil, inputs: inputs)
        }
        guard let previous = DayMath.day(targetDay, offsetBy: -1, calendar: calendar),
              let days = DayMath.days(endingOn: previous, count: p.windowDays, calendar: calendar),
              let first = days.first,
              let window = TrendAnalyzer.periodRange(first: first, last: previous, calendar: calendar)
        else {
            return spec.unavailable(.insufficientData(detail: "Invalid day"), window: nil, inputs: inputs)
        }
        let xs = DayMath.values(for: days, in: values)
        let coverage = Double(xs.count) / Double(p.windowDays)
        inputs["eligibleDays"] = "\(xs.count) of \(p.windowDays)"
        guard let stats = robustStatistics(xs, parameters: p) else {
            let reason: Availability = xs.isEmpty
                ? .calibrating(have: 0, need: p.minimumDays, unit: p.unit)
                : .lowQuality(detail: "Values are too large to summarise")
            return spec.unavailable(reason, coverage: coverage, window: window, inputs: inputs)
        }
        inputs["excludedOutliers"] = "\(stats.excluded)"
        guard stats.n >= p.minimumDays else {
            return spec.unavailable(.calibrating(have: stats.n, need: p.minimumDays, unit: p.unit), coverage: coverage,
                                    window: window, inputs: inputs)
        }
        return spec.available(stats, coverage: coverage, confidence: .forAvailable(coverage: coverage), window: window, inputs: inputs)
    }

    /// Robust statistics of the finite values (non-finite values are ignored); nil when none remain or
    /// when the values are so large that the mean or SD would not be finite.
    public static func robustStatistics(_ values: [Double], parameters p: BaselineParameters = .default) -> BaselineStatistics? {
        let xs = values.filter(\.isFinite)
        guard let median = Stats.median(xs), let mad = Stats.medianAbsoluteDeviation(xs, median: median) else { return nil }
        var kept = xs
        if mad > 0 {
            let limit = p.outlierMADMultiplier * p.madScale * mad
            kept = xs.filter { abs($0 - median) <= limit }
        }
        guard let mean = Stats.mean(kept), mean.isFinite, median.isFinite, mad.isFinite else { return nil }
        let sd = Stats.sampleStandardDeviation(kept)
        if let sd, !sd.isFinite { return nil }
        return BaselineStatistics(mean: mean, standardDeviation: sd, n: kept.count,
                                  excluded: xs.count - kept.count, median: median, medianAbsoluteDeviation: mad)
    }
}
