import Foundation
import FormaCore

/// Structural checks run before anything is written, by `ingest`, `importBackup` and the
/// session/derived writers, so both paths accept the same records (backup import adds the timeline
/// checks in `BackupValidator`, because a file is untrusted input).
///
/// They reject values that cannot be a measurement at all (empty device ID, NaN/±∞, negative
/// counts, a heart rate wider than the BLE field, a 0 bpm that no flag marks as invalid). They never
/// reject a value merely for being implausible: plausibility is expressed with `QualityFlags`, and
/// flagged records are stored as-is.
enum RecordValidator {
    /// Longest accepted identifier (device ID, metric ID, setting key), in UTF-8 bytes.
    static let maxIdentifierBytes = 256
    /// Values a heart-rate field can carry on the wire (the BLE Heart Rate Measurement format is
    /// at most UINT16). Anything else is a decoding bug, not a reading.
    static let bpmFieldRange: ClosedRange<Int> = 0...65_535
    /// FormaCore: "bpm is never 0". A 0 is accepted only as raw evidence carrying one of these flags,
    /// which exclude it from analytics (the sync engine flags out-of-range values, 0 included, as
    /// `.outOfRange`), so an unflagged 0 can never be mistaken for a measured heart rate.
    static let zeroBPMFlags: QualityFlags = [.deviceMarkedInvalid, .noSensorContact, .outOfRange]

    static func identifier(_ value: String, _ what: @autoclosure () -> String) throws {
        if value.isEmpty { throw StoreError.invalidRecord("\(what()) is empty") }
        if value.utf8.count > maxIdentifierBytes {
            throw StoreError.invalidRecord("\(what()) is longer than \(maxIdentifierBytes) bytes")
        }
    }

    static func finite(_ value: Double, _ what: @autoclosure () -> String) throws {
        if !value.isFinite { throw StoreError.invalidRecord("\(what()) is not a finite number") }
    }

    static func fraction(_ value: Double?, _ what: @autoclosure () -> String) throws {
        guard let value else { return }
        guard value.isFinite, (0...1).contains(value) else {
            throw StoreError.invalidRecord("\(what()) must be a finite fraction in 0...1")
        }
    }

    // MARK: Measurements

    static func validate(_ sample: HeartRateSample, at path: String) throws {
        try identifier(sample.deviceID, "\(path).deviceID")
        guard bpmFieldRange.contains(sample.bpm) else {
            throw StoreError.invalidRecord("\(path).bpm \(sample.bpm) is outside the encodable range \(bpmFieldRange)")
        }
        if sample.bpm == 0, sample.quality.isDisjoint(with: zeroBPMFlags) {
            throw StoreError.invalidRecord("\(path).bpm is 0 without a deviceMarkedInvalid, noSensorContact or "
                                           + "outOfRange flag (a missing reading is not a heart rate of 0)")
        }
    }

    static func validate(_ interval: BeatInterval, at path: String) throws {
        try identifier(interval.deviceID, "\(path).deviceID")
        try finite(interval.intervalMillis, "\(path).intervalMillis")
        guard interval.indexInRecord >= 0 else {
            throw StoreError.invalidRecord("\(path).indexInRecord is negative")
        }
    }

    static func validate(_ epoch: MotionEpoch, at path: String) throws {
        try identifier(epoch.deviceID, "\(path).deviceID")
        try finite(epoch.activity, "\(path).activity")
        guard epoch.epochMillis > 0 else { throw StoreError.invalidRecord("\(path).epochMillis must be positive") }
        guard epoch.sampleCount >= 0 else { throw StoreError.invalidRecord("\(path).sampleCount is negative") }
    }

    static func validate(_ measurement: AuxMeasurement, at path: String) throws {
        try identifier(measurement.deviceID, "\(path).deviceID")
        try finite(measurement.value, "\(path).value")
    }

    static func validate(_ cursor: SyncCursor, at path: String) throws {
        try identifier(cursor.deviceID, "\(path).deviceID")
        try identifier(cursor.adapterID, "\(path).adapterID")
    }

    /// Validates a whole ingest batch. Every record (and the cursor) must belong to the device named
    /// by the provenance: a mismatch would attach records to another device's provenance.
    static func validate(_ batch: IngestBatch) throws {
        let deviceID = batch.provenance.deviceID
        try identifier(deviceID, "provenance.deviceID")
        func sameDevice(_ other: String, _ path: @autoclosure () -> String) throws {
            if other != deviceID {
                throw StoreError.invalidRecord("\(path()) '\(other)' does not match provenance.deviceID '\(deviceID)'")
            }
        }
        for (index, sample) in batch.heartRates.enumerated() {
            try validate(sample, at: "heartRates[\(index)]")
            try sameDevice(sample.deviceID, "heartRates[\(index)].deviceID")
        }
        for (index, interval) in batch.beatIntervals.enumerated() {
            try validate(interval, at: "beatIntervals[\(index)]")
            try sameDevice(interval.deviceID, "beatIntervals[\(index)].deviceID")
        }
        for (index, epoch) in batch.motion.enumerated() {
            try validate(epoch, at: "motion[\(index)]")
            try sameDevice(epoch.deviceID, "motion[\(index)].deviceID")
        }
        for (index, measurement) in batch.aux.enumerated() {
            try validate(measurement, at: "aux[\(index)]")
            try sameDevice(measurement.deviceID, "aux[\(index)].deviceID")
        }
        if let cursor = batch.cursor {
            try validate(cursor, at: "cursor")
            try sameDevice(cursor.deviceID, "cursor.deviceID")
        }
    }

    // MARK: Other records

    static func validate(_ device: DeviceRecord) throws {
        try identifier(device.id, "device.id")
    }

    static func validate(_ session: Session) throws {
        if let confidence = session.confidence {
            try fraction(confidence, "session.confidence")
        }
    }

    static func validate(_ record: DerivedMetricRecord, at path: String) throws {
        try identifier(record.metricID, "\(path).metricID")
        if let value = record.value { try finite(value, "\(path).value") }
        try fraction(record.coverage, "\(path).coverage")
    }
}

/// Extra checks for backup lines. A backup file is untrusted input, so besides the shared
/// `RecordValidator` rules every timestamp that places a record on the timeline (measurement time,
/// session bounds, motion epoch length) must lie inside `FormaStore.backupTimeWindow`. Ranges built
/// from such values (`ImportReport.importedRange`, `dataBounds()`, session ranges) can then never
/// overflow `Int64` arithmetic such as `TimeRange.durationMillis`. Bookkeeping times (`received_at`,
/// `created_at`, `updated_at`, `first_seen`, cursor times) are carried as-is.
enum BackupValidator {
    static func instant(_ value: EpochMillis, _ field: String) throws {
        guard FormaStore.backupTimeWindow.contains(value) else { throw outside(value, field) }
    }

    static func sessionBounds(start: EpochMillis, end: EpochMillis) throws {
        let window = FormaStore.backupTimeWindow
        guard start >= window.start, start < window.end else { throw outside(start, "data.start_ms") }
        guard end >= window.start, end <= window.end else { throw outside(end, "data.end_ms") }
    }

    static func epochLength(_ millis: Int64) throws {
        guard millis <= FormaStore.maxBackupEpochMillis else {
            throw BackupLineError("data.epoch_ms \(millis) is longer than \(FormaStore.maxBackupEpochMillis) ms (one day)")
        }
    }

    private static func outside(_ value: EpochMillis, _ field: String) -> BackupLineError {
        let window = FormaStore.backupTimeWindow
        return BackupLineError("\(field) \(value) is outside the importable time range "
                               + "[\(TextFormat.iso8601UTC(window.start)), \(TextFormat.iso8601UTC(window.end)))")
    }
}
