import FormaCore

/// Tunable parameters of the overnight resting heart-rate estimate (defaults = spec `forma.rhr.overnight`).
public struct RestingHeartRateParameters: Hashable, Sendable, Codable {
    /// Length of each averaging window, ms (5 min).
    public var windowMillis: Int64
    /// Step between window starts, ms (1 min).
    public var stepMillis: Int64
    /// A window is eligible when usable heart rate covers at least this fraction of it.
    public var minimumWindowCoverage: Double
    /// Covered heart rate required inside sleep windows of at least `shortWindowThresholdMillis`, ms (3 h).
    public var minimumCoveredMillis: Int64
    /// Sleep windows shorter than this (5 h) use `shortWindowMinimumCoverage` instead.
    public var shortWindowThresholdMillis: Int64
    /// Coverage fraction required inside a sleep window shorter than 5 h.
    public var shortWindowMinimumCoverage: Double
    /// Longer sleep windows are rejected as malformed, ms (24 h).
    public var maximumSleepWindowMillis: Int64

    public init(windowMillis: Int64 = 300_000, stepMillis: Int64 = 60_000, minimumWindowCoverage: Double = 0.8,
                minimumCoveredMillis: Int64 = 3 * 3_600_000, shortWindowThresholdMillis: Int64 = 5 * 3_600_000,
                shortWindowMinimumCoverage: Double = 0.6, maximumSleepWindowMillis: Int64 = 24 * 3_600_000) {
        self.windowMillis = windowMillis
        self.stepMillis = stepMillis
        self.minimumWindowCoverage = minimumWindowCoverage
        self.minimumCoveredMillis = minimumCoveredMillis
        self.shortWindowThresholdMillis = shortWindowThresholdMillis
        self.shortWindowMinimumCoverage = shortWindowMinimumCoverage
        self.maximumSleepWindowMillis = maximumSleepWindowMillis
    }

    public static let `default` = RestingHeartRateParameters()

    var isValid: Bool {
        windowMillis > 0 && stepMillis >= 1_000 && windowMillis <= maximumSleepWindowMillis
            && maximumSleepWindowMillis <= 7 * 24 * 3_600_000
            && minimumWindowCoverage.isFinite && minimumWindowCoverage > 0 && minimumWindowCoverage <= 1
            && shortWindowMinimumCoverage.isFinite && shortWindowMinimumCoverage >= 0 && shortWindowMinimumCoverage <= 1
            && minimumCoveredMillis >= 0 && shortWindowThresholdMillis >= 0
    }
}

/// Result of ``RestingHeartRateEstimator/estimate(sleepWindow:samples:parameters:)``.
public struct OvernightRestingHeartRate: Hashable, Sendable, Codable {
    /// Lowest eligible 5-minute time-weighted mean, bpm, rounded to 0.1 (spec `forma.rhr.overnight`).
    public var restingHeartRate: MetricValue<Double>
    /// The 5-minute window that produced the estimate.
    public var lowestWindow: TimeRange?
    /// Windows with ≥ 80 % coverage / all windows evaluated.
    public var eligibleWindows: Int
    public var totalWindows: Int
    /// Covered heart rate inside the sleep window, ms; nil for an empty or invalid window.
    public var coveredMillis: Int64?
    /// Covered / sleep-window length; nil for an empty or invalid window.
    public var coverage: Double?

    public init(restingHeartRate: MetricValue<Double>, lowestWindow: TimeRange?, eligibleWindows: Int,
                totalWindows: Int, coveredMillis: Int64?, coverage: Double?) {
        self.restingHeartRate = restingHeartRate
        self.lowestWindow = lowestWindow
        self.eligibleWindows = eligibleWindows
        self.totalWindows = totalWindows
        self.coveredMillis = coveredMillis
        self.coverage = coverage
    }
}

/// Personal overnight resting heart rate: the lowest sustained 5-minute heart rate inside one sleep window.
public enum RestingHeartRateEstimator {
    /// Shown with the value: this is not a clinical (awake, supine) resting heart rate.
    public static let label = "Personal overnight estimate, not a clinical resting heart rate"

    /// 5-min windows slide by 1 min from the sleep-window start (a window must end inside the sleep
    /// window); a window is eligible when usable HR covers ≥ 80 % of it; the estimate is the lowest
    /// eligible time-weighted mean, rounded to 0.1 bpm (ties: earliest window). Requires ≥ 3 h of
    /// covered HR inside the sleep window, or ≥ 60 % coverage when the sleep window is shorter than 5 h;
    /// otherwise `insufficientData` stating have/need. Confidence follows sleep-window coverage.
    public static func estimate(sleepWindow: TimeRange, samples: [HeartRateSample],
                                parameters: RestingHeartRateParameters = .default) -> OvernightRestingHeartRate {
        estimate(sleepWindow: sleepWindow, series: HeartRateSeries(samples), parameters: parameters)
    }

    /// As ``estimate(sleepWindow:samples:parameters:)`` for an already canonical series.
    public static func estimate(sleepWindow: TimeRange, series: HeartRateSeries,
                                parameters p: RestingHeartRateParameters = .default) -> OvernightRestingHeartRate {
        let spec = MetricCatalog.overnightRestingHeartRate
        func fail(_ a: Availability, window: TimeRange?, covered: Int64? = nil, coverage: Double? = nil,
                  total: Int = 0, eligible: Int = 0, inputs: [String: String] = [:]) -> OvernightRestingHeartRate {
            var i = inputs
            i["label"] = label
            return OvernightRestingHeartRate(restingHeartRate: spec.unavailable(a, coverage: coverage, window: window, inputs: i),
                                             lowestWindow: nil, eligibleWindows: eligible, totalWindows: total,
                                             coveredMillis: covered, coverage: coverage)
        }
        guard p.isValid else { return fail(.disabled(reason: "Invalid resting heart-rate parameters"), window: nil) }
        guard Sanity.isSane(sleepWindow), !sleepWindow.isEmpty else {
            return fail(.insufficientData(detail: "The sleep window is empty or invalid"), window: nil)
        }
        let duration = sleepWindow.durationMillis
        let covered = series.coveredMillis(in: sleepWindow)
        let coverage = Double(covered) / Double(duration)
        guard duration <= p.maximumSleepWindowMillis else {
            return fail(.lowQuality(detail: "The sleep window is longer than \(Fmt.duration(p.maximumSleepWindowMillis))"),
                        window: sleepWindow, covered: covered, coverage: coverage)
        }
        guard duration >= p.windowMillis else {
            return fail(.insufficientData(detail: "The sleep window is shorter than \(Fmt.duration(p.windowMillis))"),
                        window: sleepWindow, covered: covered, coverage: coverage)
        }
        var inputs = ["coveredHeartRate": Fmt.duration(covered), "coverage": Fmt.percent(coverage),
                      "usableSamples": "\(series.samples(in: sleepWindow).count)"]

        if duration >= p.shortWindowThresholdMillis {
            inputs["required"] = Fmt.duration(p.minimumCoveredMillis) + " of covered heart rate"
            guard covered >= p.minimumCoveredMillis else {
                return fail(.insufficientData(detail: "Needs at least \(Fmt.duration(p.minimumCoveredMillis)) of overnight heart rate; have \(Fmt.duration(covered))"),
                            window: sleepWindow, covered: covered, coverage: coverage, inputs: inputs)
            }
        } else {
            inputs["required"] = Fmt.percent(p.shortWindowMinimumCoverage) + " coverage (sleep window shorter than \(Fmt.duration(p.shortWindowThresholdMillis)))"
            guard Threshold.meets(Double(covered), of: Double(duration), fraction: p.shortWindowMinimumCoverage) else {
                return fail(.insufficientData(detail: "Needs heart rate for at least \(Fmt.percent(p.shortWindowMinimumCoverage)) of a sleep window shorter than \(Fmt.duration(p.shortWindowThresholdMillis)); have \(Fmt.percent(coverage, decimals: 1))"),
                            window: sleepWindow, covered: covered, coverage: coverage, inputs: inputs)
            }
        }

        var best: (mean: Double, window: TimeRange)?
        var total = 0
        var eligible = 0
        var start = sleepWindow.start
        while start <= sleepWindow.end - p.windowMillis {
            let window = TimeRange(start: start, end: start + p.windowMillis)
            start += p.stepMillis
            total += 1
            let (c, w) = series.index.integrate(window)
            guard c > 0, Threshold.meets(Double(c), of: Double(p.windowMillis), fraction: p.minimumWindowCoverage) else {
                continue
            }
            eligible += 1
            let mean = Double(w) / Double(c)
            if let current = best, current.mean <= mean { continue }
            best = (mean, window)
        }
        inputs["eligibleWindows"] = "\(eligible) of \(total)"
        guard let best else {
            return fail(.lowQuality(detail: "No \(Fmt.duration(p.windowMillis)) window reached \(Fmt.percent(p.minimumWindowCoverage)) heart-rate coverage"),
                        window: sleepWindow, covered: covered, coverage: coverage, total: total, eligible: 0, inputs: inputs)
        }
        inputs["lowestWindow"] = best.window.description
        inputs["label"] = label
        let value = spec.number(Stats.rounded(best.mean, decimals: 1), coverage: coverage,
                                confidence: .forAvailable(coverage: coverage), window: sleepWindow, inputs: inputs)
        return OvernightRestingHeartRate(restingHeartRate: value, lowestWindow: best.window, eligibleWindows: eligible,
                                         totalWindows: total, coveredMillis: covered, coverage: coverage)
    }
}
