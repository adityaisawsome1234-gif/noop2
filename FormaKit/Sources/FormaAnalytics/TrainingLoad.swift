import Foundation
import FormaCore

/// Heart-rate-based training load (specs `forma.load.edwards` and `forma.load.banister`).
///
/// **Forma Load (Edwards TRIMP)** = Σ minutes in the %HRmax bands 50–60, 60–70, 70–80, 80–90 and
/// ≥ 90 % (including above 100 %) × weights 1, 2, 3, 4, 5. Lower band bounds are inclusive; time
/// below 50 % HRmax scores 0. Minutes come from the coverage spans of usable heart rate (see
/// ``HeartRateSeries``); minutes without usable heart rate contribute nothing and nothing is
/// extrapolated. Edwards bands always use %HRmax, whatever zone model the user displays.
///
/// Reasons are reported in the order a person can act on them: an invalid range first, then a missing
/// setting (HRmax; for Banister also resting heart rate and sex), then too little heart-rate data.
public enum TrainingLoad {
    /// Lower bounds of the Edwards bands as fractions of HRmax.
    public static let edwardsBandLowerBounds: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    /// Weight per Edwards band (index 0 = the 50–60 % band).
    public static let edwardsWeights: [Double] = [1, 2, 3, 4, 5]
    /// Daily load is withheld below this heart-rate coverage of the local day.
    public static let dailyMinimumCoverage = 0.3
    /// Workout load (Edwards and Banister) is withheld below this coverage of the workout.
    public static let workoutMinimumCoverage = 0.5
    /// Banister weighting y = a·e^(b·x): men a = 0.64, b = 1.92; women a = 0.86, b = 1.67.
    public static let banisterMaleCoefficient = 0.64
    public static let banisterMaleExponent = 1.92
    public static let banisterFemaleCoefficient = 0.86
    public static let banisterFemaleExponent = 1.67
    /// Reasons shown when a Banister input is missing.
    public static let missingSexDetail = "Banister TRIMP needs your sex to choose its published weighting; Forma never assumes it"
    public static let missingRestingDetail = "Banister TRIMP needs your resting heart rate"

    /// Load for one local day (`[start of day, start of the next day)` in `calendar`'s time zone; `day` is a
    /// Gregorian date), in arbitrary units. Unavailable without HRmax; value nil when heart-rate coverage of
    /// the day is below 30 %.
    public static func dailyLoad(day: LocalDay, calendar: Calendar, samples: [HeartRateSample],
                                 hrMax: MaxHeartRate?) -> MetricValue<Double> {
        dailyLoad(day: day, calendar: calendar, series: HeartRateSeries(samples), hrMax: hrMax)
    }

    /// As ``dailyLoad(day:calendar:samples:hrMax:)`` for an already canonical series.
    public static func dailyLoad(day: LocalDay, calendar: Calendar, series: HeartRateSeries,
                                 hrMax: MaxHeartRate?) -> MetricValue<Double> {
        guard let range = DayMath.range(of: day, calendar: calendar) else {
            return MetricCatalog.edwardsLoad.unavailable(.insufficientData(detail: "Invalid day"), window: nil)
        }
        return edwardsLoad(range: range, series: series, hrMax: hrMax, minimumCoverage: dailyMinimumCoverage, scope: "day")
    }

    /// Edwards load for one workout, in arbitrary units; withheld below 50 % coverage.
    public static func workoutLoad(range: TimeRange, samples: [HeartRateSample], hrMax: MaxHeartRate?) -> MetricValue<Double> {
        workoutLoad(range: range, series: HeartRateSeries(samples), hrMax: hrMax)
    }

    /// As ``workoutLoad(range:samples:hrMax:)`` for an already canonical series.
    public static func workoutLoad(range: TimeRange, series: HeartRateSeries, hrMax: MaxHeartRate?) -> MetricValue<Double> {
        edwardsLoad(range: range, series: series, hrMax: hrMax, minimumCoverage: workoutMinimumCoverage, scope: "workout")
    }

    /// Banister TRIMP for a workout: Σ minutes × x × a·e^(b·x) with x = (HR − HRrest) / (HRmax − HRrest)
    /// clamped to 0…1. Only computed when HRmax, resting HR (25–120 bpm, below HRmax) and sex are known;
    /// sex is never assumed. Withheld below 50 % coverage.
    public static func banisterTRIMP(range: TimeRange, samples: [HeartRateSample], hrMax: MaxHeartRate?,
                                     restingHeartRate: Double?, sex: UserProfile.Sex) -> MetricValue<Double> {
        banisterTRIMP(range: range, series: HeartRateSeries(samples), hrMax: hrMax, restingHeartRate: restingHeartRate, sex: sex)
    }

    /// As ``banisterTRIMP(range:samples:hrMax:restingHeartRate:sex:)`` for an already canonical series.
    public static func banisterTRIMP(range: TimeRange, series: HeartRateSeries, hrMax: MaxHeartRate?,
                                     restingHeartRate: Double?, sex: UserProfile.Sex) -> MetricValue<Double> {
        let spec = MetricCatalog.banisterTRIMP
        guard let gate = coverageGate(range: range, series: series, minimumCoverage: workoutMinimumCoverage, scope: "workout") else {
            return spec.unavailable(.insufficientData(detail: "The workout time range is empty or invalid"), window: nil)
        }
        var inputs = gate.inputs
        guard let hrMax, hrMax.bpm.isFinite, hrMax.bpm > 0 else {
            return spec.unavailable(.insufficientData(detail: MaxHeartRateResolver.missingInputDetail),
                                    coverage: gate.coverage, window: range, inputs: inputs)
        }
        inputs["maxHeartRate"] = Fmt.bpm(hrMax.bpm) + " (\(hrMax.label))"
        guard let rest = restingHeartRate, HeartRateZones.restingHeartRateRange.contains(rest), rest < hrMax.bpm else {
            return spec.unavailable(.insufficientData(detail: missingRestingDetail), coverage: gate.coverage, window: range, inputs: inputs)
        }
        inputs["restingHeartRate"] = Fmt.bpm(rest)
        let a: Double, b: Double
        switch sex {
        case .female:
            a = banisterFemaleCoefficient
            b = banisterFemaleExponent
        case .male:
            a = banisterMaleCoefficient
            b = banisterMaleExponent
        case .unspecified:
            return spec.unavailable(.insufficientData(detail: missingSexDetail), coverage: gate.coverage, window: range, inputs: inputs)
        }
        if let failure = gate.failure {
            return spec.unavailable(failure, coverage: gate.coverage, window: range, inputs: inputs)
        }
        inputs["weighting"] = "\(sex.rawValue): \(Fmt.number(a, decimals: 2))·e^(\(Fmt.number(b, decimals: 2))·x)"
        let reserve = hrMax.bpm - rest
        var trimp = 0.0
        series.index.forEachOverlap(range) { i, start, end in
            let x = Stats.clamp((Double(series.index.bpms[i]) - rest) / reserve, 0, 1)
            trimp += Double(end - start) / 60_000 * x * a * exp(b * x)
        }
        let confidence = min(Confidence.forAvailable(coverage: gate.coverage), hrMax.confidenceCap)
        return spec.number(Stats.rounded(trimp, decimals: 1), coverage: gate.coverage, confidence: confidence,
                           window: range, inputs: inputs)
    }

    // MARK: Internals

    /// Milliseconds per Edwards band (index 0 = below 50 % HRmax) and the resulting TRIMP.
    struct EdwardsBreakdown {
        var millisByBand: [Int64]
        var trimp: Double
    }

    static func edwardsBreakdown(series: HeartRateSeries, range: TimeRange, hrMax: Double) -> EdwardsBreakdown {
        let bounds = edwardsBandLowerBounds.map { $0 * hrMax }
        var ms = [Int64](repeating: 0, count: bounds.count + 1)
        series.index.forEachOverlap(range) { i, start, end in
            ms[HeartRateZones.zoneIndex(bpm: Double(series.index.bpms[i]), lowerBounds: bounds)] += end - start
        }
        var trimp = 0.0
        for band in 1..<ms.count {
            trimp += Double(ms[band]) / 60_000 * edwardsWeights[band - 1]
        }
        return EdwardsBreakdown(millisByBand: ms, trimp: trimp)
    }

    /// Shared data gate: nil for an empty/invalid range; otherwise coverage plus the failure, if any.
    struct CoverageGate {
        var coverage: Double
        var inputs: [String: String]
        var failure: Availability?
    }

    static func coverageGate(range: TimeRange, series: HeartRateSeries, minimumCoverage: Double, scope: String) -> CoverageGate? {
        guard Sanity.isSane(range), !range.isEmpty else { return nil }
        let covered = series.coveredMillis(in: range)
        let coverage = Double(covered) / Double(range.durationMillis)
        let inside = series.samples(in: range).count
        let inputs = ["coverage": Fmt.percent(coverage), "minimumCoverage": Fmt.percent(minimumCoverage),
                      "usableSamples": "\(inside)"]
        var failure: Availability?
        if inside == 0 || covered == 0 {
            failure = .insufficientData(detail: "No usable heart-rate samples in this \(scope)")
        } else if !Threshold.meets(Double(covered), of: Double(range.durationMillis), fraction: minimumCoverage) {
            failure = .lowQuality(detail: "Heart rate covers \(Fmt.percent(coverage, decimals: 1)) of this \(scope); at least \(Fmt.percent(minimumCoverage)) is needed")
        }
        return CoverageGate(coverage: coverage, inputs: inputs, failure: failure)
    }

    static func edwardsLoad(range: TimeRange, series: HeartRateSeries, hrMax: MaxHeartRate?,
                            minimumCoverage: Double, scope: String) -> MetricValue<Double> {
        let spec = MetricCatalog.edwardsLoad
        guard let gate = coverageGate(range: range, series: series, minimumCoverage: minimumCoverage, scope: scope) else {
            return spec.unavailable(.insufficientData(detail: "The \(scope) time range is empty or invalid"), window: nil)
        }
        var inputs = gate.inputs
        guard let hrMax, hrMax.bpm.isFinite, hrMax.bpm > 0 else {
            return spec.unavailable(.insufficientData(detail: MaxHeartRateResolver.missingInputDetail),
                                    coverage: gate.coverage, window: range, inputs: inputs)
        }
        inputs["maxHeartRate"] = Fmt.bpm(hrMax.bpm) + " (\(hrMax.label))"
        if let failure = gate.failure {
            return spec.unavailable(failure, coverage: gate.coverage, window: range, inputs: inputs)
        }
        let breakdown = edwardsBreakdown(series: series, range: range, hrMax: hrMax.bpm)
        let names = ["50–60%", "60–70%", "70–80%", "80–90%", "≥90%"]
        inputs["minutesByBand"] = zip(names, breakdown.millisByBand.dropFirst())
            .map { "\($0): \(Fmt.number(Double($1) / 60_000, decimals: 1)) min" }
            .joined(separator: ", ")
        let confidence = min(Confidence.forAvailable(coverage: gate.coverage), hrMax.confidenceCap)
        return spec.number(Stats.rounded(breakdown.trimp, decimals: 1), coverage: gate.coverage, confidence: confidence,
                           window: range, inputs: inputs)
    }
}
