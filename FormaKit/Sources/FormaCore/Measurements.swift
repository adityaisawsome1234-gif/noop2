import Foundation

/// Where a measurement came from. Stored with every record so that live, historical,
/// standard-service and imported data are never confused.
public enum MeasurementSource: Int, Sendable, Codable, CaseIterable, CustomStringConvertible {
    /// Real-time notifications on the vendor data path. Timestamp semantics are documented per adapter.
    case liveVendorStream = 1
    /// Records downloaded from the band's own stored history (device-timestamped).
    case deviceHistory = 2
    /// Bluetooth SIG Heart Rate Service (0x180D / 0x2A37). Carries no timestamps: time is phone receive time.
    case standardHeartRateService = 3
    /// Restored from a Forma backup file.
    case backupImport = 4
    /// Synthetic data used only in Demo mode, which uses a separate database file.
    case demo = 9

    public var description: String {
        switch self {
        case .liveVendorStream: return "live (vendor stream)"
        case .deviceHistory: return "band history"
        case .standardHeartRateService: return "standard heart-rate service"
        case .backupImport: return "backup import"
        case .demo: return "demo"
        }
    }

    /// True when the timestamp was assigned by the device clock rather than by the phone on receipt.
    public var hasDeviceTimestamp: Bool {
        switch self {
        case .deviceHistory: return true
        case .liveVendorStream, .standardHeartRateService, .backupImport, .demo: return false
        }
    }
}

/// Per-record quality flags. Raw measurements are never altered; flags describe them.
public struct QualityFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }

    /// Timestamp was taken from the phone's receive time (no device clock available).
    public static let phoneReceiveTime = QualityFlags(rawValue: 1 << 0)
    /// Timestamp was mapped from device time using an inferred clock offset.
    public static let clockOffsetApplied = QualityFlags(rawValue: 1 << 1)
    /// Record lies next to a detected clock discontinuity (jump/reset/restart); its absolute time is uncertain.
    public static let nearClockDiscontinuity = QualityFlags(rawValue: 1 << 2)
    /// Value outside the physiologically plausible range for its kind (kept, but excluded from analytics).
    public static let outOfRange = QualityFlags(rawValue: 1 << 3)
    /// The device reported that skin/sensor contact was NOT detected.
    public static let noSensorContact = QualityFlags(rawValue: 1 << 4)
    /// The device indicated the reading is not valid/settled (e.g. HR value 0 or a "no signal" marker).
    public static let deviceMarkedInvalid = QualityFlags(rawValue: 1 << 5)
    /// The record was decoded from a field whose meaning is not yet validated for this firmware.
    public static let unvalidatedField = QualityFlags(rawValue: 1 << 6)
    /// Device time could not be mapped to wall time with confidence.
    public static let clockUnmapped = QualityFlags(rawValue: 1 << 7)
}

/// A single heart-rate value as reported by a device. `bpm` is never 0: "no reading" is
/// represented by not storing a sample (or by `deviceMarkedInvalid` when we keep raw evidence).
public struct HeartRateSample: Hashable, Sendable, Codable {
    public var deviceID: String
    /// Normalized UTC time of the measurement.
    public var timestamp: EpochMillis
    public var bpm: Int
    public var source: MeasurementSource
    /// The device's own time value for this record, in the adapter's documented unit (nil when the source has none).
    public var deviceTimeRaw: Int64?
    /// When the phone received the bytes.
    public var receivedAt: EpochMillis
    /// Clock correction applied when mapping device time to `timestamp`, if any.
    public var clockOffsetMillis: Int64?
    public var quality: QualityFlags
    /// Ingest batch carrying provenance (adapter, parser version, firmware, sync run).
    public var batchID: Int64?

    public init(deviceID: String, timestamp: EpochMillis, bpm: Int, source: MeasurementSource,
                deviceTimeRaw: Int64? = nil, receivedAt: EpochMillis, clockOffsetMillis: Int64? = nil,
                quality: QualityFlags = [], batchID: Int64? = nil) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.bpm = bpm
        self.source = source
        self.deviceTimeRaw = deviceTimeRaw
        self.receivedAt = receivedAt
        self.clockOffsetMillis = clockOffsetMillis
        self.quality = quality
        self.batchID = batchID
    }

    /// Plausibility bounds used to flag (not delete) implausible values.
    public static let plausibleRange: ClosedRange<Int> = 25...240
}

/// A measured beat-to-beat (RR or optical pulse-to-pulse) interval taken from a field the device
/// itself emits. Forma never derives these from heart rate (no `60_000 / bpm`).
public struct BeatInterval: Hashable, Sendable, Codable {
    public var deviceID: String
    /// Best-known time of the beat that closes this interval. For sources without per-beat timing this
    /// is reconstructed from the containing record's time; see `timingBasis`.
    public var timestamp: EpochMillis
    /// Interval length in milliseconds, converted from the device unit (e.g. 1/1024 s) without rounding.
    public var intervalMillis: Double
    public var source: MeasurementSource
    /// Stable key of the containing record/notification (device record time or receive time), used for dedup.
    public var recordKey: Int64
    /// Position of this interval within its record.
    public var indexInRecord: Int
    public var receivedAt: EpochMillis
    public var timingBasis: BeatTimingBasis
    public var quality: QualityFlags
    public var batchID: Int64?

    public init(deviceID: String, timestamp: EpochMillis, intervalMillis: Double, source: MeasurementSource,
                recordKey: Int64, indexInRecord: Int, receivedAt: EpochMillis,
                timingBasis: BeatTimingBasis, quality: QualityFlags = [], batchID: Int64? = nil) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.intervalMillis = intervalMillis
        self.source = source
        self.recordKey = recordKey
        self.indexInRecord = indexInRecord
        self.receivedAt = receivedAt
        self.timingBasis = timingBasis
        self.quality = quality
        self.batchID = batchID
    }

    /// Physiologically plausible interval bounds (≈ 30–200 bpm). Outside values are flagged, not deleted.
    public static let plausibleMillis: ClosedRange<Double> = 300...2_000
}

/// How a beat interval's timestamp was obtained.
public enum BeatTimingBasis: Int, Sendable, Codable {
    /// Reconstructed backwards from a notification's phone receive time (standard HR service).
    case reconstructedFromReceiveTime = 1
    /// Reconstructed from the containing device record's timestamp.
    case reconstructedFromRecordTime = 2
}

/// Motion summary for an epoch (e.g. 1 s or 60 s), computed from device-provided accelerometer data.
public struct MotionEpoch: Hashable, Sendable, Codable {
    public var deviceID: String
    public var timestamp: EpochMillis
    public var epochMillis: Int64
    /// Movement intensity over the epoch, in source-specific units (for WHOOP 5.0 band history: mean
    /// absolute deviation of the accelerometer magnitude from its median, in raw device counts — scale
    /// unpublished). Analytics use only thresholds relative to the user's own data, never absolute units.
    public var activity: Double
    /// Number of raw accelerometer samples that contributed (0 means no motion data for the epoch).
    public var sampleCount: Int
    public var source: MeasurementSource
    public var quality: QualityFlags
    public var batchID: Int64?

    public init(deviceID: String, timestamp: EpochMillis, epochMillis: Int64, activity: Double,
                sampleCount: Int, source: MeasurementSource, quality: QualityFlags = [], batchID: Int64? = nil) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.epochMillis = epochMillis
        self.activity = activity
        self.sampleCount = sampleCount
        self.source = source
        self.quality = quality
        self.batchID = batchID
    }
}

/// Conditional measurements whose sensor path and interpretation must be validated per device/firmware
/// before Forma shows them (temperature, SpO2, respiratory rate, battery, ...).
public enum AuxKind: String, Sendable, Codable, CaseIterable {
    case batteryPercent
    case skinTemperatureCelsius
    case spo2Percent
    case respiratoryRateBrpm
    case skinContact
}

public struct AuxMeasurement: Hashable, Sendable, Codable {
    public var deviceID: String
    public var timestamp: EpochMillis
    public var kind: AuxKind
    public var value: Double
    public var source: MeasurementSource
    /// False until the field's meaning and units are validated for this device/firmware.
    public var validated: Bool
    public var quality: QualityFlags
    public var batchID: Int64?

    public init(deviceID: String, timestamp: EpochMillis, kind: AuxKind, value: Double,
                source: MeasurementSource, validated: Bool, quality: QualityFlags = [], batchID: Int64? = nil) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.kind = kind
        self.value = value
        self.source = source
        self.validated = validated
        self.quality = quality
        self.batchID = batchID
    }
}
