import Foundation

public enum SessionKind: String, Hashable, Sendable, Codable, CaseIterable {
    case workout
    case sleep
}

/// How a session came to exist. Detected sessions are only candidates until the user confirms them.
public enum SessionOrigin: String, Hashable, Sendable, Codable {
    /// Started/stopped by the user in the workout recorder, or a sleep window typed in by the user.
    case manual
    /// Proposed by a detector; not used for "confirmed" totals until the user accepts it.
    case detectedCandidate
    /// A detected candidate the user accepted unchanged.
    case userConfirmed
    /// A detected candidate whose bounds the user changed.
    case userEdited
    /// Restored from a backup.
    case imported
}

public struct Session: Hashable, Sendable, Codable, Identifiable {
    public var id: Int64?
    public var kind: SessionKind
    public var range: TimeRange
    public var origin: SessionOrigin
    public var label: String?
    public var deviceID: String?
    /// Detector identifier + version for detected sessions (nil for manual).
    public var detector: String?
    /// Detector confidence 0…1 (nil for manual sessions).
    public var confidence: Double?
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deleted: Bool

    public init(id: Int64? = nil, kind: SessionKind, range: TimeRange, origin: SessionOrigin, label: String? = nil,
                deviceID: String? = nil, detector: String? = nil, confidence: Double? = nil,
                createdAt: EpochMillis, updatedAt: EpochMillis, deleted: Bool = false) {
        self.id = id
        self.kind = kind
        self.range = range
        self.origin = origin
        self.label = label
        self.deviceID = deviceID
        self.detector = detector
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    /// Sessions that count toward confirmed summaries (candidates do not).
    public var isConfirmed: Bool { origin != .detectedCandidate && !deleted }
}

/// Audit trail of user corrections; derived metrics overlapping a corrected range are recomputed.
public struct UserCorrection: Hashable, Sendable, Codable {
    public var id: Int64?
    public var sessionID: Int64?
    public var field: String
    public var oldValue: String?
    public var newValue: String?
    public var createdAt: EpochMillis

    public init(id: Int64? = nil, sessionID: Int64?, field: String, oldValue: String?, newValue: String?, createdAt: EpochMillis) {
        self.id = id
        self.sessionID = sessionID
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.createdAt = createdAt
    }
}

/// A cached derived value. Recomputed (and overwritten) when inputs or the spec version change.
public struct DerivedMetricRecord: Hashable, Sendable, Codable {
    public var metricID: String
    public var specVersion: Int
    public var window: TimeRange
    public var value: Double?
    public var unit: String
    public var availability: String
    public var coverage: Double?
    public var confidence: Confidence
    public var inputsJSON: String
    public var computedAt: EpochMillis

    public init(metricID: String, specVersion: Int, window: TimeRange, value: Double?, unit: String,
                availability: String, coverage: Double?, confidence: Confidence, inputsJSON: String, computedAt: EpochMillis) {
        self.metricID = metricID
        self.specVersion = specVersion
        self.window = window
        self.value = value
        self.unit = unit
        self.availability = availability
        self.coverage = coverage
        self.confidence = confidence
        self.inputsJSON = inputsJSON
        self.computedAt = computedAt
    }
}

/// User profile inputs used by zone/load calculations. All optional: features that need a
/// missing input are suppressed with an explanation rather than guessed.
public struct UserProfile: Hashable, Sendable, Codable {
    public enum Sex: String, Hashable, Sendable, Codable { case female, male, unspecified }

    public var birthYear: Int?
    public var sex: Sex
    /// User-entered maximum heart rate. Preferred over any estimate.
    public var maxHeartRateOverride: Int?
    /// User-entered resting heart rate (otherwise Forma's overnight estimate is used when available).
    public var restingHeartRateOverride: Int?

    public init(birthYear: Int? = nil, sex: Sex = .unspecified, maxHeartRateOverride: Int? = nil, restingHeartRateOverride: Int? = nil) {
        self.birthYear = birthYear
        self.sex = sex
        self.maxHeartRateOverride = maxHeartRateOverride
        self.restingHeartRateOverride = restingHeartRateOverride
    }
}
