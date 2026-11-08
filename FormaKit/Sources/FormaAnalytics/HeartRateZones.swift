import Foundation
import FormaCore

// MARK: - Maximum heart rate

/// Maximum heart rate used by zones and training load, with its provenance (spec `forma.hr.max`).
public struct MaxHeartRate: Hashable, Sendable, Codable {
    /// Where the value came from.
    public enum Basis: String, Hashable, Sendable, Codable {
        /// Entered by the user; always preferred.
        case userOverride
        /// Tanaka et al. (2001): 208 − 0.7 × age.
        case estimatedFromAge
    }

    /// Beats per minute.
    public var bpm: Double
    public var basis: Basis
    /// Age in whole years used for the estimate (nil for a user override).
    public var ageYears: Int?

    public init(bpm: Double, basis: Basis, ageYears: Int? = nil) {
        self.bpm = bpm
        self.basis = basis
        self.ageYears = ageYears
    }

    /// Provenance label shown next to the value: "set by you" or "estimated from age".
    public var label: String {
        switch basis {
        case .userOverride: return "set by you"
        case .estimatedFromAge: return "estimated from age"
        }
    }

    /// Ceiling on the confidence of anything derived from this HRmax. An age-based estimate (individual
    /// error ≈ ±10 bpm) is itself reported with `.low` confidence by ``MaxHeartRateResolver``, so zones,
    /// time in zone and load built on it are capped at `.low` too; a user override does not cap (`.high`).
    public var confidenceCap: Confidence {
        basis == .userOverride ? .high : .low
    }
}

/// Resolves HRmax by precedence: user override > Tanaka age estimate > unavailable.
public enum MaxHeartRateResolver {
    /// A user override outside this range (bpm) is ignored (and reported in `inputs`).
    public static let overrideRange: ClosedRange<Int> = 100...240
    /// Ages (years) for which the age formula is applied.
    public static let ageRange: ClosedRange<Int> = 13...100
    /// Tanaka et al. (2001): HRmax = 208 − 0.7 × age (bpm).
    public static let tanakaIntercept = 208.0
    public static let tanakaSlope = 0.7
    /// Reason shown when neither input is available.
    public static let missingInputDetail = "Set your max heart rate or birth year"
    /// Reference dates (epoch ms, 1900-01-01 … 2200-01-01 UTC) for which an age is computed at all.
    static let plausibleReferenceDates: ClosedRange<EpochMillis> = -2_208_988_800_000...7_258_118_400_000

    /// 208 − 0.7 × age, rounded to 0.1 bpm. A building block: it does not check ``ageRange``, so use
    /// ``resolve(profile:asOf:calendar:)`` for values shown to people.
    public static func tanakaEstimate(ageYears: Int) -> Double {
        Stats.rounded(tanakaIntercept - tanakaSlope * Double(ageYears), decimals: 1)
    }

    /// Resolves HRmax for the moment `asOf`. Age = Gregorian year of `asOf` in `calendar`'s time zone
    /// minus `birthYear` (birth date unknown, so the age can be one year too high).
    /// Confidence: `.high` for a user override, `.low` for the age estimate.
    public static func resolve(profile: UserProfile, asOf: EpochMillis, calendar: Calendar) -> MetricValue<MaxHeartRate> {
        let spec = MetricCatalog.maxHeartRate
        var inputs: [String: String] = [:]
        if let o = profile.maxHeartRateOverride {
            if overrideRange.contains(o) {
                inputs["maxHeartRate"] = "\(o) bpm (set by you)"
                return spec.available(MaxHeartRate(bpm: Double(o), basis: .userOverride), coverage: nil,
                                      confidence: .high, window: nil, inputs: inputs)
            }
            inputs["ignoredOverride"] = "\(o) bpm is outside \(overrideRange.lowerBound)–\(overrideRange.upperBound) bpm"
        }
        if profile.birthYear != nil, !plausibleReferenceDates.contains(asOf) {
            inputs["ignoredBirthYear"] = "the reference date is invalid"
        } else if let birthYear = profile.birthYear {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let year = gregorian.component(.year, from: asOf.date)
            let (age, overflow) = year.subtractingReportingOverflow(birthYear)
            if !overflow, ageRange.contains(age) {
                let bpm = tanakaEstimate(ageYears: age)
                inputs["birthYear"] = "\(birthYear)"
                inputs["ageYears"] = "\(age)"
                inputs["maxHeartRate"] = Fmt.bpm(bpm) + " (estimated from age: \(Fmt.number(tanakaIntercept, decimals: 0)) − \(Fmt.number(tanakaSlope)) × \(age))"
                return spec.available(MaxHeartRate(bpm: bpm, basis: .estimatedFromAge, ageYears: age), coverage: nil,
                                      confidence: .low, window: nil, inputs: inputs)
            }
            inputs["ignoredBirthYear"] = "\(birthYear) gives an age outside \(ageRange.lowerBound)–\(ageRange.upperBound) years"
        }
        return spec.unavailable(.insufficientData(detail: missingInputDetail), window: nil, inputs: inputs)
    }
}

// MARK: - Zones

/// How zone bounds are derived from the boundary fractions.
public enum HeartRateZoneModel: String, Hashable, Sendable, Codable, CaseIterable {
    /// bound = fraction × HRmax.
    case percentMax
    /// Karvonen: bound = HRrest + fraction × (HRmax − HRrest).
    case heartRateReserve
}

/// Resolved zone bounds in bpm.
public struct ZoneThresholds: Hashable, Sendable, Codable {
    public var model: HeartRateZoneModel
    /// Boundary fractions (lower bounds of zones 1…k).
    public var boundaries: [Double]
    /// Inclusive lower bound of zones 1…k, bpm (unrounded).
    public var lowerBoundsBPM: [Double]
    public var maxHeartRate: MaxHeartRate
    /// Resting heart rate used by the heart-rate-reserve model, bpm.
    public var restingHeartRate: Double?

    public init(model: HeartRateZoneModel, boundaries: [Double], lowerBoundsBPM: [Double],
                maxHeartRate: MaxHeartRate, restingHeartRate: Double?) {
        self.model = model
        self.boundaries = boundaries
        self.lowerBoundsBPM = lowerBoundsBPM
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
    }

    /// Zone of a heart rate: 0 = "below zones", otherwise 1…k. Lower bounds are inclusive.
    public func zone(forBPM bpm: Double) -> Int {
        HeartRateZones.zoneIndex(bpm: bpm, lowerBounds: lowerBoundsBPM)
    }
}

/// Heart-rate zone configuration (spec `forma.hr.zones`).
public struct HeartRateZones: Hashable, Sendable, Codable {
    /// Default boundaries: zones 1–5 start at 50, 60, 70, 80 and 90 %.
    public static let defaultBoundaries: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    /// Label of zone 0.
    public static let belowZonesLabel = "below zones"
    /// Resting heart rates (bpm) accepted by the heart-rate-reserve model.
    public static let restingHeartRateRange: ClosedRange<Double> = 25...120
    /// Reason shown when the heart-rate-reserve model has no usable resting heart rate.
    public static let missingRestingDetail = "Set your resting heart rate, or wear the band overnight, to use heart-rate-reserve zones"
    /// Tolerance (bpm) so a heart rate exactly on a bound lands in the higher zone despite rounding.
    static let boundaryTolerance = 1e-9

    public var model: HeartRateZoneModel
    /// Lower bounds of zones 1…k as fractions: strictly increasing, each in (0, 1], at most 10.
    public var boundaries: [Double]
    public var maxHeartRate: MaxHeartRate?
    /// Required for `.heartRateReserve` (bpm).
    public var restingHeartRate: Double?

    public init(model: HeartRateZoneModel = .percentMax, boundaries: [Double] = HeartRateZones.defaultBoundaries,
                maxHeartRate: MaxHeartRate?, restingHeartRate: Double? = nil) {
        self.model = model
        self.boundaries = boundaries
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
    }

    /// Builds zones from the profile: HRmax via ``MaxHeartRateResolver``; resting HR = the profile's
    /// override (if within 25–120 bpm) or else `overnightRestingHeartRate` (Forma's estimate).
    public static func resolve(profile: UserProfile, asOf: EpochMillis, calendar: Calendar,
                               model: HeartRateZoneModel = .percentMax,
                               boundaries: [Double] = HeartRateZones.defaultBoundaries,
                               overnightRestingHeartRate: Double? = nil) -> HeartRateZones {
        let hrMax = MaxHeartRateResolver.resolve(profile: profile, asOf: asOf, calendar: calendar).value
        var resting: Double?
        if let o = profile.restingHeartRateOverride, restingHeartRateRange.contains(Double(o)) {
            resting = Double(o)
        } else if let e = overnightRestingHeartRate, e.isFinite {
            resting = e
        }
        return HeartRateZones(model: model, boundaries: boundaries, maxHeartRate: hrMax, restingHeartRate: resting)
    }

    /// Number of zones above zone 0.
    public var zoneCount: Int { boundaries.count }

    /// "below zones" for 0, otherwise "Zone k".
    public static func label(forZone zone: Int) -> String {
        zone <= 0 ? belowZonesLabel : "Zone \(zone)"
    }

    static func validBoundaries(_ b: [Double]) -> Bool {
        guard !b.isEmpty, b.count <= 10 else { return false }
        var previous = 0.0
        for x in b {
            guard x.isFinite, x > previous, x <= 1 else { return false }
            previous = x
        }
        return true
    }

    /// Zone bounds in bpm, or the reason they cannot be computed. Confidence is ``MaxHeartRate/confidenceCap``
    /// (high for your own HRmax, low for the age estimate).
    public func thresholds() -> MetricValue<ZoneThresholds> {
        let spec = MetricCatalog.heartRateZones
        switch resolution() {
        case .failed(let availability, let hrMax):
            var inputs: [String: String] = [:]
            if let hrMax { inputs = baseInputs(hrMax) }
            return spec.unavailable(availability, window: nil, inputs: inputs)
        case .resolved(let bounds, let hrMax, let resting):
            var inputs = baseInputs(hrMax)
            if let resting { inputs["restingHeartRate"] = Fmt.bpm(resting) }
            let thresholds = ZoneThresholds(model: model, boundaries: boundaries, lowerBoundsBPM: bounds,
                                            maxHeartRate: hrMax, restingHeartRate: resting)
            return spec.available(thresholds, coverage: nil, confidence: hrMax.confidenceCap, window: nil, inputs: inputs)
        }
    }

    /// Zone (0…k) of `bpm`, or nil when thresholds are unavailable. Cheap enough to call per chart point:
    /// it resolves the bounds without building the explanation that ``thresholds()`` carries.
    public func zone(forBPM bpm: Double) -> Int? {
        guard case .resolved(let bounds, _, _) = resolution() else { return nil }
        return Self.zoneIndex(bpm: bpm, lowerBounds: bounds)
    }

    /// Resolved lower bounds (bpm), or why they cannot be computed (with HRmax when it was usable).
    enum Resolution {
        case resolved(bounds: [Double], hrMax: MaxHeartRate, resting: Double?)
        case failed(Availability, hrMax: MaxHeartRate?)
    }

    func resolution() -> Resolution {
        guard Self.validBoundaries(boundaries) else {
            return .failed(.disabled(reason: "Zone boundaries must be strictly increasing fractions in (0, 1]"), hrMax: nil)
        }
        guard let hrMax = maxHeartRate, hrMax.bpm.isFinite, hrMax.bpm > 0 else {
            return .failed(.insufficientData(detail: MaxHeartRateResolver.missingInputDetail), hrMax: nil)
        }
        switch model {
        case .percentMax:
            return .resolved(bounds: boundaries.map { $0 * hrMax.bpm }, hrMax: hrMax, resting: nil)
        case .heartRateReserve:
            guard let r = restingHeartRate, Self.restingHeartRateRange.contains(r), r < hrMax.bpm else {
                return .failed(.insufficientData(detail: Self.missingRestingDetail), hrMax: hrMax)
            }
            return .resolved(bounds: boundaries.map { r + $0 * (hrMax.bpm - r) }, hrMax: hrMax, resting: r)
        }
    }

    private func baseInputs(_ hrMax: MaxHeartRate) -> [String: String] {
        ["model": model.rawValue,
         "maxHeartRate": Fmt.bpm(hrMax.bpm) + " (\(hrMax.label))",
         "boundaries": boundaries.map { Fmt.percent($0) }.joined(separator: ", ")]
    }

    /// Count of ascending lower bounds that `bpm` reaches (inclusive, with a 1e-9 bpm tolerance).
    static func zoneIndex(bpm: Double, lowerBounds: [Double]) -> Int {
        var zone = 0
        for bound in lowerBounds {
            if bpm + boundaryTolerance >= bound { zone += 1 } else { break }
        }
        return zone
    }
}
