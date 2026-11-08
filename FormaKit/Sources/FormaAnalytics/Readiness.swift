import Foundation
import FormaCore

/// Component weights of the experimental readiness composite (non-negative; HRV must be > 0).
public struct ReadinessWeights: Hashable, Sendable, Codable {
    public var hrv: Double
    public var restingHeartRate: Double
    public var sleepDuration: Double

    public init(hrv: Double = 0.5, restingHeartRate: Double = 0.3, sleepDuration: Double = 0.2) {
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.sleepDuration = sleepDuration
    }

    public static let `default` = ReadinessWeights()

    public func weight(for kind: ReadinessComponentKind) -> Double {
        switch kind {
        case .hrv: return hrv
        case .restingHeartRate: return restingHeartRate
        case .sleepDuration: return sleepDuration
        }
    }
}

/// Parameters of the experimental readiness composite (defaults = spec `forma.readiness.experimental`).
public struct ReadinessParameters: Hashable, Sendable, Codable {
    /// Nights before the target night used for each baseline (target night excluded).
    public var baselineDays: Int
    /// Retained baseline nights required per component.
    public var hrvMinimumNights: Int
    public var restingHeartRateMinimumNights: Int
    public var sleepMinimumNights: Int
    /// SD floors: the z-score denominator is max(baseline SD, floor).
    public var lnRMSSDStandardDeviationFloor: Double
    public var restingHeartRateStandardDeviationFloor: Double
    public var sleepStandardDeviationFloorMinutes: Double
    public var weights: ReadinessWeights
    /// |composite| above this many SD leaves "within usual".
    public var bandThreshold: Double
    /// Confidence is high only with all three components and at least this many HRV baseline nights.
    public var highConfidenceMinimumHRVNights: Int

    public init(baselineDays: Int = 28, hrvMinimumNights: Int = 14, restingHeartRateMinimumNights: Int = 14,
                sleepMinimumNights: Int = 7, lnRMSSDStandardDeviationFloor: Double = 0.05,
                restingHeartRateStandardDeviationFloor: Double = 1.0, sleepStandardDeviationFloorMinutes: Double = 30,
                weights: ReadinessWeights = .default, bandThreshold: Double = 1.0, highConfidenceMinimumHRVNights: Int = 21) {
        self.baselineDays = baselineDays
        self.hrvMinimumNights = hrvMinimumNights
        self.restingHeartRateMinimumNights = restingHeartRateMinimumNights
        self.sleepMinimumNights = sleepMinimumNights
        self.lnRMSSDStandardDeviationFloor = lnRMSSDStandardDeviationFloor
        self.restingHeartRateStandardDeviationFloor = restingHeartRateStandardDeviationFloor
        self.sleepStandardDeviationFloorMinutes = sleepStandardDeviationFloorMinutes
        self.weights = weights
        self.bandThreshold = bandThreshold
        self.highConfidenceMinimumHRVNights = highConfidenceMinimumHRVNights
    }

    public static let `default` = ReadinessParameters()

    var isValid: Bool {
        let nights = [hrvMinimumNights, restingHeartRateMinimumNights, sleepMinimumNights]
        let floors = [lnRMSSDStandardDeviationFloor, restingHeartRateStandardDeviationFloor, sleepStandardDeviationFloorMinutes]
        let w = [weights.hrv, weights.restingHeartRate, weights.sleepDuration]
        return (1...366).contains(baselineDays) && nights.allSatisfy { $0 >= 1 && $0 <= baselineDays }
            && floors.allSatisfy { $0.isFinite && $0 > 0 }
            && w.allSatisfy { $0.isFinite && $0 >= 0 } && weights.hrv > 0 && w.reduce(0, +).isFinite
            && bandThreshold.isFinite && bandThreshold > 0
    }
}

/// Where the composite sits relative to the person's own recent baseline. Descriptive only.
public enum ReadinessBand: String, Hashable, Sendable, Codable, CaseIterable {
    /// Composite < −1.0 SD.
    case belowUsual = "below usual"
    /// −1.0 ≤ composite ≤ +1.0 SD.
    case withinUsual = "within usual"
    /// Composite > +1.0 SD.
    case aboveUsual = "above usual"

    public var label: String { rawValue }
}

/// The inputs of the readiness composite.
public enum ReadinessComponentKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Overnight lnRMSSD (ln ms).
    case hrv
    /// Overnight resting heart rate (bpm); sign inverted (lower than usual → positive z).
    case restingHeartRate
    /// Confirmed sleep duration (minutes).
    case sleepDuration
}

/// One input of the composite, with everything needed to show how it was used.
public struct ReadinessComponent: Hashable, Sendable, Codable {
    public var kind: ReadinessComponentKind
    /// Target-night value (lnRMSSD, bpm or minutes); nil when missing.
    public var value: Double?
    public var unit: String
    /// Baseline over the previous nights (mean, SD, n, excluded), or the calibration state.
    public var baseline: MetricValue<BaselineStatistics>
    public var standardDeviationFloor: Double
    /// max(baseline SD, floor); nil when the baseline is unavailable.
    public var standardDeviationUsed: Double?
    /// True for resting heart rate.
    public var signInverted: Bool
    /// (value − mean) / SD used, sign-inverted for resting HR, rounded to 0.01 for display. The composite
    /// is computed from the unrounded z.
    public var z: Double?
    public var weight: Double
    /// Whether the component entered the composite.
    public var isIncluded: Bool
    /// `.available` when included; otherwise why not (missing value, calibrating, …).
    public var availability: Availability
    /// Calibration progress: retained baseline nights (eligible nights minus those excluded as outliers,
    /// the baseline's n) / nights required. `baseline.inputs` lists eligible and excluded nights.
    public var calibrationHave: Int
    public var calibrationNeed: Int

    public init(kind: ReadinessComponentKind, value: Double?, unit: String, baseline: MetricValue<BaselineStatistics>,
                standardDeviationFloor: Double, standardDeviationUsed: Double?, signInverted: Bool, z: Double?,
                weight: Double, isIncluded: Bool, availability: Availability, calibrationHave: Int, calibrationNeed: Int) {
        self.kind = kind
        self.value = value
        self.unit = unit
        self.baseline = baseline
        self.standardDeviationFloor = standardDeviationFloor
        self.standardDeviationUsed = standardDeviationUsed
        self.signInverted = signInverted
        self.z = z
        self.weight = weight
        self.isIncluded = isIncluded
        self.availability = availability
        self.calibrationHave = calibrationHave
        self.calibrationNeed = calibrationNeed
    }
}

/// Result of ``ReadinessCalculator/compute(day:calendar:lnRMSSD:restingHeartRate:sleepDurationMinutes:parameters:)``.
public struct ReadinessResult: Hashable, Sendable, Codable {
    public var day: LocalDay
    /// Σ wᵢzᵢ / Σ wᵢ over included components (unrounded zᵢ), in SD units (not a 0–100 score), rounded once
    /// to 0.01.
    public var composite: MetricValue<Double>
    /// Band of the rounded composite, so the band always agrees with the value shown; nil when the
    /// composite is unavailable.
    public var band: ReadinessBand?
    /// HRV, resting HR and sleep, in that order.
    public var components: [ReadinessComponent]
    public var weights: ReadinessWeights
    public var parameters: ReadinessParameters

    public init(day: LocalDay, composite: MetricValue<Double>, band: ReadinessBand?, components: [ReadinessComponent],
                weights: ReadinessWeights, parameters: ReadinessParameters) {
        self.day = day
        self.composite = composite
        self.band = band
        self.components = components
        self.weights = weights
        self.parameters = parameters
    }

    /// The component of `kind`, if computed.
    public func component(_ kind: ReadinessComponentKind) -> ReadinessComponent? {
        components.first { $0.kind == kind }
    }
}

/// Experimental readiness composite: how the target night compares with the person's own previous
/// nights. It is descriptive only and carries no training or treatment advice.
public enum ReadinessCalculator {
    /// - Parameters:
    ///   - day: the target night, keyed by the local (Gregorian) day on which it ends.
    ///   - lnRMSSD: overnight lnRMSSD per night (ln ms), e.g. `HRVAnalysis.lnRMSSD`.
    ///   - restingHeartRate: overnight resting HR per night (bpm), e.g. `OvernightRestingHeartRate`.
    ///   - sleepDurationMinutes: confirmed sleep duration per night (minutes); use one definition consistently.
    ///   Values for `day` are the target values; the previous `baselineDays` nights form the baselines.
    public static func compute(day: LocalDay, calendar: Calendar, lnRMSSD: [LocalDay: Double?],
                               restingHeartRate: [LocalDay: Double?], sleepDurationMinutes: [LocalDay: Double?],
                               parameters p: ReadinessParameters = .default) -> ReadinessResult {
        let spec = MetricCatalog.readiness
        let window = DayMath.range(of: day, calendar: calendar)
        guard p.isValid else {
            return ReadinessResult(day: day, composite: spec.unavailable(.disabled(reason: "Invalid readiness parameters"), window: window),
                                   band: nil, components: [], weights: p.weights, parameters: p)
        }
        let computed = [
            component(.hrv, values: lnRMSSD, day: day, calendar: calendar, minimumNights: p.hrvMinimumNights,
                      floor: p.lnRMSSDStandardDeviationFloor, unit: "ln(ms)", parameters: p),
            component(.restingHeartRate, values: restingHeartRate, day: day, calendar: calendar,
                      minimumNights: p.restingHeartRateMinimumNights, floor: p.restingHeartRateStandardDeviationFloor,
                      unit: "bpm", parameters: p),
            component(.sleepDuration, values: sleepDurationMinutes, day: day, calendar: calendar,
                      minimumNights: p.sleepMinimumNights, floor: p.sleepStandardDeviationFloorMinutes, unit: "min", parameters: p),
        ]
        let components = computed.map(\.component)
        var inputs = ["scale": "SD units relative to your previous \(p.baselineDays) nights (not a 0–100 score)",
                      "weights": "HRV \(Fmt.number(p.weights.hrv, decimals: 2)), resting HR \(Fmt.number(p.weights.restingHeartRate, decimals: 2)), sleep \(Fmt.number(p.weights.sleepDuration, decimals: 2))"]
        for c in components { inputs[c.kind.rawValue] = describe(c) }

        guard let hrv = components.first, hrv.kind == .hrv, hrv.isIncluded else {
            let reason = components.first?.availability ?? .insufficientData(detail: "No overnight HRV for this night")
            return ReadinessResult(day: day, composite: spec.unavailable(reason, window: window, inputs: inputs),
                                   band: nil, components: components, weights: p.weights, parameters: p)
        }
        // Unrounded z values: rounding each z first could move the composite across a band threshold.
        var sumW = 0.0, sumWZ = 0.0
        for c in computed where c.component.isIncluded {
            guard let z = c.unroundedZ else { continue }
            sumW += c.component.weight
            sumWZ += c.component.weight * z
        }
        let totalWeight = p.weights.hrv + p.weights.restingHeartRate + p.weights.sleepDuration
        let coverage = totalWeight > 0 ? sumW / totalWeight : nil
        let included = components.filter(\.isIncluded).count
        let confidence: Confidence
        if included == 3, hrv.calibrationHave >= p.highConfidenceMinimumHRVNights {
            confidence = .high
        } else if included >= 2 {
            confidence = .moderate
        } else {
            confidence = .low
        }
        let composite = Stats.rounded(sumWZ / sumW, decimals: 2)
        let value = spec.number(composite, coverage: coverage, confidence: confidence, window: window, inputs: inputs)
        return ReadinessResult(day: day, composite: value,
                               band: value.value.map { band(for: $0, threshold: p.bandThreshold) },
                               components: components, weights: p.weights, parameters: p)
    }

    /// below usual (< −threshold), within usual (−threshold…+threshold inclusive), above usual (> +threshold).
    public static func band(for composite: Double, threshold: Double = 1.0) -> ReadinessBand {
        if composite < -threshold { return .belowUsual }
        if composite > threshold { return .aboveUsual }
        return .withinUsual
    }

    /// A component and its unrounded z (nil when it is not included).
    struct ComputedComponent {
        var component: ReadinessComponent
        var unroundedZ: Double?
    }

    static func component(_ kind: ReadinessComponentKind, values: [LocalDay: Double?], day: LocalDay, calendar: Calendar,
                          minimumNights: Int, floor: Double, unit: String, parameters p: ReadinessParameters) -> ComputedComponent {
        let baseline = BaselineCalculator.baseline(
            values: values, targetDay: day, calendar: calendar,
            parameters: BaselineParameters(windowDays: p.baselineDays, minimumDays: minimumNights, unit: "nights"))
        var have = 0
        if let stats = baseline.value {
            have = stats.n
        } else if case let .calibrating(h, _, _) = baseline.availability {
            have = h
        }
        let weight = p.weights.weight(for: kind)
        let inverted = kind == .restingHeartRate
        var value: Double?
        if let entry = values[day], let v = entry, v.isFinite { value = v }
        let sdUsed = baseline.value.map { max($0.standardDeviation ?? 0, floor) }

        func excluded(_ a: Availability) -> ComputedComponent {
            ComputedComponent(component: ReadinessComponent(kind: kind, value: value, unit: unit, baseline: baseline,
                                                            standardDeviationFloor: floor, standardDeviationUsed: sdUsed,
                                                            signInverted: inverted, z: nil, weight: weight, isIncluded: false,
                                                            availability: a, calibrationHave: have, calibrationNeed: minimumNights),
                              unroundedZ: nil)
        }
        guard let value else { return excluded(.insufficientData(detail: "No \(name(of: kind)) for this night")) }
        guard let stats = baseline.value, let sd = sdUsed else { return excluded(baseline.availability) }
        guard weight > 0 else { return excluded(.disabled(reason: "Weight is 0")) }
        let raw = (value - stats.mean) / sd
        let z = inverted ? -raw : raw
        guard z.isFinite else { return excluded(.lowQuality(detail: "The z-score is not finite")) }
        return ComputedComponent(
            component: ReadinessComponent(kind: kind, value: value, unit: unit, baseline: baseline, standardDeviationFloor: floor,
                                          standardDeviationUsed: sd, signInverted: inverted, z: Stats.rounded(z, decimals: 2),
                                          weight: weight, isIncluded: true, availability: .available, calibrationHave: have,
                                          calibrationNeed: minimumNights),
            unroundedZ: z)
    }

    static func name(of kind: ReadinessComponentKind) -> String {
        switch kind {
        case .hrv: return "overnight HRV"
        case .restingHeartRate: return "overnight resting heart rate"
        case .sleepDuration: return "confirmed sleep duration"
        }
    }

    static func describe(_ c: ReadinessComponent) -> String {
        let excludedNights = c.baseline.value?.excluded ?? c.baseline.inputs["excludedOutliers"].flatMap { Int($0) } ?? 0
        let exclusionNote = excludedNights > 0
            ? "; \(excludedNights) unusual night\(excludedNights == 1 ? "" : "s") left out of the baseline as \(excludedNights == 1 ? "an outlier" : "outliers")"
            : ""
        guard c.isIncluded, let v = c.value, let stats = c.baseline.value, let sd = c.standardDeviationUsed, let z = c.z else {
            return "not included: \(c.availability.explanation) (baseline \(c.calibrationHave) of \(c.calibrationNeed) nights\(exclusionNote))"
        }
        let decimals = c.kind == .hrv ? 3 : 1
        return "\(Fmt.number(v, decimals: decimals)) \(c.unit) vs baseline \(Fmt.number(stats.mean, decimals: decimals)) ± \(Fmt.number(sd, decimals: decimals)) (n=\(stats.n)\(exclusionNote)); z \(Fmt.signed(z))\(c.signInverted ? " (sign inverted)" : ""); weight \(Fmt.number(c.weight, decimals: 2))"
    }
}
