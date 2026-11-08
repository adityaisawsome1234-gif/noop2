import Foundation

/// Why a metric does or does not have a value. Every screen renders from this, so "no value"
/// always comes with a concrete, user-readable reason instead of a zero or an empty ring.
public enum Availability: Hashable, Sendable, Codable {
    /// A value is present and passed its quality gates.
    case available
    /// Not enough usable input in the analysis window (e.g. "needs ≥ 3 h overnight HR; have 1 h 12 min").
    case insufficientData(detail: String)
    /// Baseline-dependent metric still collecting eligible days/nights.
    case calibrating(have: Int, need: Int, unit: String)
    /// The connected band/firmware does not provide a required input (e.g. beat intervals, motion).
    case unsupportedSensor(sensor: String)
    /// Input exists but failed quality gates (artifacts, low coverage, clock uncertainty).
    case lowQuality(detail: String)
    /// Data for the window may still be on the band and has not been synchronized yet.
    case notYetSynced(detail: String)
    /// Feature is intentionally off (e.g. experimental metric not enabled, or not validated for this device).
    case disabled(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Short explanation suitable for a secondary label.
    public var explanation: String {
        switch self {
        case .available: return "Available"
        case .insufficientData(let d): return d
        case .calibrating(let have, let need, let unit): return "Calibrating: \(have) of \(need) \(unit)"
        case .unsupportedSensor(let s): return "Not provided by this band: \(s)"
        case .lowQuality(let d): return d
        case .notYetSynced(let d): return d
        case .disabled(let r): return r
        }
    }
}

/// Confidence label shown next to every derived value.
public enum Confidence: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case none, low, moderate, high

    private var rank: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .moderate: return 2
        case .high: return 3
        }
    }

    public static func < (a: Confidence, b: Confidence) -> Bool { a.rank < b.rank }

    /// Simple coverage-based mapping used where a metric has no better-founded confidence model.
    public static func fromCoverage(_ coverage: Double?) -> Confidence {
        guard let c = coverage else { return .none }
        switch c {
        case 0.9...: return .high
        case 0.7..<0.9: return .moderate
        case 0.0001..<0.7: return .low
        default: return .none
        }
    }
}

/// A derived value with everything needed to display it honestly.
/// `value` is `nil` whenever `availability` is not `.available` — never a placeholder zero.
public struct MetricValue<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    public var value: Value?
    public var availability: Availability
    /// Fraction (0…1) of the analysis window with usable input, if meaningful for this metric.
    public var coverage: Double?
    public var confidence: Confidence
    public var window: TimeRange?
    /// Identifier and version of the `MetricSpec` that produced this value.
    public var specID: String
    public var specVersion: Int
    /// Human-readable inputs actually used (exposed in the UI's "How this was calculated" sheet).
    public var inputs: [String: String]

    public init(value: Value?, availability: Availability, coverage: Double?, confidence: Confidence,
                window: TimeRange?, specID: String, specVersion: Int, inputs: [String: String] = [:]) {
        // Enforce the invariant: no value without availability, no availability without value.
        if availability.isAvailable, value != nil {
            self.value = value
            self.availability = availability
        } else if availability.isAvailable {
            self.value = nil
            self.availability = .insufficientData(detail: "No value could be computed")
        } else {
            self.value = nil
            self.availability = availability
        }
        self.coverage = coverage
        self.confidence = self.value == nil ? .none : confidence
        self.window = window
        self.specID = specID
        self.specVersion = specVersion
        self.inputs = inputs
    }

    public static func unavailable(_ availability: Availability, specID: String, specVersion: Int,
                                   window: TimeRange? = nil, coverage: Double? = nil,
                                   inputs: [String: String] = [:]) -> MetricValue {
        MetricValue(value: nil, availability: availability, coverage: coverage, confidence: .none,
                    window: window, specID: specID, specVersion: specVersion, inputs: inputs)
    }
}

/// How settled a metric's methodology is. Shown with the value so estimates are never mistaken
/// for measurements.
public enum MetricStatus: String, Hashable, Sendable, Codable {
    /// Directly reported by the device (e.g. heart rate).
    case measured
    /// Computed from measurements with a documented, published method (e.g. RMSSD, Edwards TRIMP).
    case estimate
    /// Forma-defined composite or heuristic still under evaluation (e.g. readiness index).
    case experimental
}

/// Machine- and human-readable description of a metric. The Methodology screen renders these,
/// so documentation and implementation cannot drift apart.
public struct MetricSpec: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var version: Int
    public var status: MetricStatus
    public var unit: String
    public var requiredInputs: [String]
    public var qualityGates: [String]
    public var method: String
    public var windowing: String
    public var baseline: String?
    public var limitations: [String]
    public var references: [String]

    public init(id: String, name: String, version: Int, status: MetricStatus, unit: String,
                requiredInputs: [String], qualityGates: [String], method: String, windowing: String,
                baseline: String?, limitations: [String], references: [String]) {
        self.id = id
        self.name = name
        self.version = version
        self.status = status
        self.unit = unit
        self.requiredInputs = requiredInputs
        self.qualityGates = qualityGates
        self.method = method
        self.windowing = windowing
        self.baseline = baseline
        self.limitations = limitations
        self.references = references
    }
}
