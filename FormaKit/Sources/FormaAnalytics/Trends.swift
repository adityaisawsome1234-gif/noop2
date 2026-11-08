import Foundation
import FormaCore

/// Trend periods and their minimum number of days with data (spec `forma.trends`).
public enum TrendPeriod: Int, Hashable, Sendable, Codable, CaseIterable {
    case days7 = 7
    case days30 = 30
    case days90 = 90

    /// Calendar days in the period (ending on, and including, the end day).
    public var days: Int { rawValue }

    /// Days with data required for statistics: 7 → 4, 30 → 14, 90 → 45.
    public var minimumDaysWithData: Int {
        switch self {
        case .days7: return 4
        case .days30: return 14
        case .days90: return 45
        }
    }
}

/// Descriptive statistics of the daily values in a period (no interpretation).
public struct TrendStatistics: Hashable, Sendable, Codable {
    /// Days in the period with a finite value.
    public var daysWithData: Int
    /// Mean, median, SD, minimum and maximum are in the summarised metric's unit.
    public var mean: Double
    public var median: Double
    /// Sample standard deviation (n − 1); nil for fewer than two values.
    public var standardDeviation: Double?
    public var minimum: Double
    public var maximum: Double

    public init(daysWithData: Int, mean: Double, median: Double, standardDeviation: Double?, minimum: Double, maximum: Double) {
        self.daysWithData = daysWithData
        self.mean = mean
        self.median = median
        self.standardDeviation = standardDeviation
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// One period's summary.
public struct TrendSummary: Hashable, Sendable, Codable {
    public var period: TrendPeriod
    /// First and last calendar day of the period (nil first day only for an invalid end day).
    public var firstDay: LocalDay?
    public var lastDay: LocalDay
    /// Days in the period that have a finite value.
    public var daysWithData: Int
    public var statistics: MetricValue<TrendStatistics>

    public init(period: TrendPeriod, firstDay: LocalDay?, lastDay: LocalDay, daysWithData: Int,
                statistics: MetricValue<TrendStatistics>) {
        self.period = period
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.daysWithData = daysWithData
        self.statistics = statistics
    }
}

/// Mean of the last 7 days compared with the mean of the 28 days before them.
public struct RecentVersusPrior: Hashable, Sendable, Codable {
    /// Mean of the days with data among the end day and the 6 days before it.
    public var recentMean: Double
    public var recentDays: Int
    /// Mean of the days with data among the 28 days before the recent week.
    public var priorMean: Double
    public var priorDays: Int
    /// recentMean − priorMean, in the metric's unit.
    public var difference: Double
    /// 100 × difference / priorMean, only for ratio-scale values: nil when the prior mean is not positive,
    /// when the recent mean is negative, or for a metric whose values are not on a ratio scale (see
    /// ``TrendAnalyzer/nonRatioMetricIDs``), where a percentage would be meaningless.
    public var percentDifference: Double?

    public init(recentMean: Double, recentDays: Int, priorMean: Double, priorDays: Int, difference: Double, percentDifference: Double?) {
        self.recentMean = recentMean
        self.recentDays = recentDays
        self.priorMean = priorMean
        self.priorDays = priorDays
        self.difference = difference
        self.percentDifference = percentDifference
    }
}

/// Descriptive trend statistics over daily values. Missing keys, explicit `nil` and non-finite values
/// all mean "no data that day". The output describes the numbers only: no causes, no advice.
/// Days are Gregorian dates in `calendar`'s time zone (see `LocalDay`); only the time zone is used.
public enum TrendAnalyzer {
    /// Comparison windows (days): the last 7 days (end day included) vs the 28 days before them.
    public static let recentDays = 7
    public static let priorDays = 28
    /// Days with data required in each comparison window.
    public static let recentMinimumDays = 4
    public static let priorMinimumDays = 14
    /// Metrics whose values are not on a ratio scale (SD units, logarithms): no percentage difference.
    public static let nonRatioMetricIDs: Set<String> = [MetricID.readiness, MetricID.hrvLnRMSSD]

    /// Statistics for `period` ending on `lastDay` (inclusive). Confidence follows the share of days
    /// with data (≥ 90 % high, ≥ 70 % moderate, otherwise low). `daysWithData` is 0 for an invalid end day.
    /// - Parameter metricID: optional spec ID of the summarised metric, echoed in `inputs`.
    public static func summary(of values: [LocalDay: Double?], period: TrendPeriod, endingOn lastDay: LocalDay,
                               calendar: Calendar, metricID: String? = nil) -> TrendSummary {
        let spec = MetricCatalog.trends
        var inputs = ["period": "\(period.days) days", "minimumDays": "\(period.minimumDaysWithData)"]
        if let metricID { inputs["metric"] = metricID }
        guard let days = DayMath.days(endingOn: lastDay, count: period.days, calendar: calendar),
              let first = days.first,
              let window = periodRange(first: first, last: lastDay, calendar: calendar)
        else {
            return TrendSummary(period: period, firstDay: nil, lastDay: lastDay, daysWithData: 0,
                                statistics: spec.unavailable(.insufficientData(detail: "Invalid day"), window: nil, inputs: inputs))
        }
        let xs = DayMath.values(for: days, in: values)
        let coverage = Double(xs.count) / Double(period.days)
        inputs["daysWithData"] = "\(xs.count) of \(period.days)"
        guard xs.count >= period.minimumDaysWithData,
              let mean = Stats.mean(xs), let median = Stats.median(xs),
              let lo = xs.min(), let hi = xs.max()
        else {
            let detail = "Needs at least \(period.minimumDaysWithData) of \(period.days) days with data; have \(xs.count)"
            return TrendSummary(period: period, firstDay: first, lastDay: lastDay, daysWithData: xs.count,
                                statistics: spec.unavailable(.insufficientData(detail: detail), coverage: coverage,
                                                             window: window, inputs: inputs))
        }
        let stats = TrendStatistics(daysWithData: xs.count, mean: mean, median: median,
                                    standardDeviation: Stats.sampleStandardDeviation(xs), minimum: lo, maximum: hi)
        let value: MetricValue<TrendStatistics> = mean.isFinite && (stats.standardDeviation?.isFinite ?? true)
            ? spec.available(stats, coverage: coverage, confidence: .forAvailable(coverage: coverage), window: window, inputs: inputs)
            : spec.unavailable(.lowQuality(detail: "Values are too large to summarise"), coverage: coverage, window: window, inputs: inputs)
        return TrendSummary(period: period, firstDay: first, lastDay: lastDay, daysWithData: xs.count, statistics: value)
    }

    /// Summaries for 7, 30 and 90 days ending on `lastDay`.
    public static func summaries(of values: [LocalDay: Double?], endingOn lastDay: LocalDay, calendar: Calendar,
                                 metricID: String? = nil) -> [TrendSummary] {
        TrendPeriod.allCases.map { summary(of: values, period: $0, endingOn: lastDay, calendar: calendar, metricID: metricID) }
    }

    /// Last-7-day mean vs the prior-28-day mean; available only with ≥ 4 of 7 and ≥ 14 of 28 days with data.
    /// - Parameter metricID: spec ID of the summarised metric. Pass it: it is echoed in `inputs` and decides
    ///   whether a percentage difference is meaningful (none for ``nonRatioMetricIDs``).
    public static func recentVersusPrior(of values: [LocalDay: Double?], endingOn lastDay: LocalDay,
                                         calendar: Calendar, metricID: String? = nil) -> MetricValue<RecentVersusPrior> {
        let spec = MetricCatalog.trends
        var inputs = ["comparison": "last \(recentDays) days vs the \(priorDays) days before them"]
        if let metricID { inputs["metric"] = metricID }
        guard let all = DayMath.days(endingOn: lastDay, count: recentDays + priorDays, calendar: calendar),
              let first = all.first,
              let window = periodRange(first: first, last: lastDay, calendar: calendar)
        else {
            return spec.unavailable(.insufficientData(detail: "Invalid day"), window: nil, inputs: inputs)
        }
        let prior = DayMath.values(for: Array(all.prefix(priorDays)), in: values)
        let recent = DayMath.values(for: Array(all.suffix(recentDays)), in: values)
        inputs["recentDays"] = "\(recent.count) of \(recentDays)"
        inputs["priorDays"] = "\(prior.count) of \(priorDays)"
        let coverage = Double(recent.count + prior.count) / Double(recentDays + priorDays)
        guard recent.count >= recentMinimumDays, prior.count >= priorMinimumDays,
              let recentMean = Stats.mean(recent), let priorMean = Stats.mean(prior)
        else {
            let detail = "Needs at least \(recentMinimumDays) of the last \(recentDays) days and \(priorMinimumDays) of the \(priorDays) days before; have \(recent.count) and \(prior.count)"
            return spec.unavailable(.insufficientData(detail: detail), coverage: coverage, window: window, inputs: inputs)
        }
        let difference = recentMean - priorMean
        let ratioScale = !(metricID.map(nonRatioMetricIDs.contains) ?? false)
        let percent: Double? = ratioScale && priorMean > 0 && recentMean >= 0 ? 100 * difference / priorMean : nil
        guard difference.isFinite, percent?.isFinite ?? true else {
            return spec.unavailable(.lowQuality(detail: "Values are too large to compare"), coverage: coverage, window: window, inputs: inputs)
        }
        let result = RecentVersusPrior(recentMean: recentMean, recentDays: recent.count, priorMean: priorMean,
                                       priorDays: prior.count, difference: difference, percentDifference: percent)
        return spec.available(result, coverage: coverage, confidence: .forAvailable(coverage: coverage), window: window, inputs: inputs)
    }

    static func periodRange(first: LocalDay, last: LocalDay, calendar: Calendar) -> TimeRange? {
        guard let a = DayMath.range(of: first, calendar: calendar), let b = DayMath.range(of: last, calendar: calendar) else { return nil }
        return TimeRange(start: a.start, end: b.end)
    }
}
