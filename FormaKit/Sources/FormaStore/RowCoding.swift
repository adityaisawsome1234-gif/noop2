import Foundation
import FormaCore

/// Column lists and row decoders shared by queries, CSV export and the backup writer.
///
/// Decoders return nil (the row is skipped) instead of inventing a value when a stored NOT NULL
/// field is missing or holds a code this build does not know. `base` is the index of the first
/// listed column in the result row, so the same decoder works behind extra leading columns.
enum RowDecoder {
    static let heartRateColumns =
        "device_id, ts_ms, bpm, source, device_time_raw, received_at, clock_offset_ms, quality, batch_id"

    static func heartRate(_ s: SQLiteStatement, _ base: Int = 0) -> HeartRateSample? {
        guard let deviceID = s.string(base), let timestamp = s.int64(base + 1), let bpm = s.int(base + 2),
              let source = s.int(base + 3).flatMap(MeasurementSource.init(rawValue:)),
              let receivedAt = s.int64(base + 5) else { return nil }
        return HeartRateSample(deviceID: deviceID, timestamp: timestamp, bpm: bpm, source: source,
                               deviceTimeRaw: s.int64(base + 4), receivedAt: receivedAt,
                               clockOffsetMillis: s.int64(base + 6),
                               quality: QualityFlags(rawValue: s.int64(base + 7) ?? 0), batchID: s.int64(base + 8))
    }

    static let beatIntervalColumns =
        "device_id, ts_ms, interval_ms, source, record_key, idx, received_at, timing_basis, quality, batch_id"

    static func beatInterval(_ s: SQLiteStatement, _ base: Int = 0) -> BeatInterval? {
        guard let deviceID = s.string(base), let timestamp = s.int64(base + 1), let interval = s.double(base + 2),
              let source = s.int(base + 3).flatMap(MeasurementSource.init(rawValue:)),
              let recordKey = s.int64(base + 4), let index = s.int(base + 5), let receivedAt = s.int64(base + 6),
              let basis = s.int(base + 7).flatMap(BeatTimingBasis.init(rawValue:)) else { return nil }
        return BeatInterval(deviceID: deviceID, timestamp: timestamp, intervalMillis: interval, source: source,
                            recordKey: recordKey, indexInRecord: index, receivedAt: receivedAt, timingBasis: basis,
                            quality: QualityFlags(rawValue: s.int64(base + 8) ?? 0), batchID: s.int64(base + 9))
    }

    static let motionColumns = "device_id, ts_ms, epoch_ms, activity, sample_count, source, quality, batch_id"

    static func motion(_ s: SQLiteStatement, _ base: Int = 0) -> MotionEpoch? {
        guard let deviceID = s.string(base), let timestamp = s.int64(base + 1), let epoch = s.int64(base + 2),
              let activity = s.double(base + 3), let count = s.int(base + 4),
              let source = s.int(base + 5).flatMap(MeasurementSource.init(rawValue:)) else { return nil }
        return MotionEpoch(deviceID: deviceID, timestamp: timestamp, epochMillis: epoch, activity: activity,
                           sampleCount: count, source: source,
                           quality: QualityFlags(rawValue: s.int64(base + 6) ?? 0), batchID: s.int64(base + 7))
    }

    static let auxColumns = "device_id, ts_ms, kind, value, source, validated, quality, batch_id"

    static func aux(_ s: SQLiteStatement, _ base: Int = 0) -> AuxMeasurement? {
        guard let deviceID = s.string(base), let timestamp = s.int64(base + 1),
              let kind = s.string(base + 2).flatMap(AuxKind.init(rawValue:)), let value = s.double(base + 3),
              let source = s.int(base + 4).flatMap(MeasurementSource.init(rawValue:)) else { return nil }
        return AuxMeasurement(deviceID: deviceID, timestamp: timestamp, kind: kind, value: value, source: source,
                              validated: s.bool(base + 5) ?? false,
                              quality: QualityFlags(rawValue: s.int64(base + 6) ?? 0), batchID: s.int64(base + 7))
    }

    static let deviceColumns = "id, family, name, firmware, hardware, first_seen, last_connected"

    /// An unrecognized family string is reported as `.unknown` (that case exists for exactly this).
    static func device(_ s: SQLiteStatement, _ base: Int = 0) -> DeviceRecord? {
        guard let id = s.string(base), let name = s.string(base + 2), let firstSeen = s.int64(base + 5) else {
            return nil
        }
        let family = s.string(base + 1).flatMap(DeviceFamily.init(rawValue:)) ?? .unknown
        return DeviceRecord(id: id, family: family, name: name, firmwareVersion: s.string(base + 3),
                            hardwareRevision: s.string(base + 4), firstSeen: firstSeen,
                            lastConnected: s.int64(base + 6))
    }

    static let provenanceColumns =
        "device_id, adapter_id, parser_version, firmware, source, sync_run_id, created_at, note"

    static func provenance(_ s: SQLiteStatement, _ base: Int = 0) -> Provenance? {
        guard let deviceID = s.string(base), let adapterID = s.string(base + 1), let parser = s.string(base + 2),
              let source = s.int(base + 4).flatMap(MeasurementSource.init(rawValue:)),
              let createdAt = s.int64(base + 6) else { return nil }
        return Provenance(deviceID: deviceID, adapterID: adapterID, parserVersion: parser,
                          firmwareVersion: s.string(base + 3), source: source, syncRunID: s.int64(base + 5),
                          createdAt: createdAt, note: s.string(base + 7))
    }

    static let cursorColumns = "device_id, adapter_id, opaque, newest_record_ms, last_complete_ms, updated_at"

    static func cursor(_ s: SQLiteStatement, _ base: Int = 0) -> SyncCursor? {
        guard let deviceID = s.string(base), let adapterID = s.string(base + 1),
              let updatedAt = s.int64(base + 5) else { return nil }
        return SyncCursor(deviceID: deviceID, adapterID: adapterID, opaque: s.data(base + 2),
                          newestPersistedRecordTime: s.int64(base + 3), lastCompleteSyncAt: s.int64(base + 4),
                          updatedAt: updatedAt)
    }

    static let syncRunColumns =
        "id, device_id, started_at, ended_at, status, batches, records_inserted, duplicates, malformed_frames, note"

    static func syncRun(_ s: SQLiteStatement, _ base: Int = 0) -> SyncRunRecord? {
        guard let id = s.int64(base), let deviceID = s.string(base + 1), let startedAt = s.int64(base + 2),
              let status = s.string(base + 4).flatMap(SyncRunRecord.Status.init(rawValue:)) else { return nil }
        return SyncRunRecord(id: id, deviceID: deviceID, startedAt: startedAt, endedAt: s.int64(base + 3),
                             status: status, batches: s.int(base + 5) ?? 0, recordsInserted: s.int(base + 6) ?? 0,
                             duplicates: s.int(base + 7) ?? 0, malformedFrames: s.int(base + 8) ?? 0,
                             note: s.string(base + 9))
    }

    static let rawFrameColumns = "device_id, received_at, characteristic, bytes, parse_status"

    static func rawFrame(_ s: SQLiteStatement, _ base: Int = 0) -> RawFrameRecord? {
        guard let receivedAt = s.int64(base + 1), let characteristic = s.string(base + 2),
              let bytes = s.data(base + 3), let status = s.string(base + 4) else { return nil }
        return RawFrameRecord(deviceID: s.string(base), receivedAt: receivedAt, characteristic: characteristic,
                              bytes: bytes, parseStatus: status)
    }

    static let connectionEventColumns = "device_id, ts_ms, kind, detail"

    static func connectionEvent(_ s: SQLiteStatement, _ base: Int = 0) -> ConnectionEvent? {
        guard let timestamp = s.int64(base + 1),
              let kind = s.string(base + 2).flatMap(ConnectionEventKind.init(rawValue:)) else { return nil }
        return ConnectionEvent(deviceID: s.string(base), timestamp: timestamp, kind: kind, detail: s.string(base + 3))
    }

    static let sessionColumns =
        "id, kind, start_ms, end_ms, origin, label, device_id, detector, confidence, created_at, updated_at, deleted"

    static func session(_ s: SQLiteStatement, _ base: Int = 0) -> Session? {
        guard let id = s.int64(base), let kind = s.string(base + 1).flatMap(SessionKind.init(rawValue:)),
              let start = s.int64(base + 2), let end = s.int64(base + 3),
              let origin = s.string(base + 4).flatMap(SessionOrigin.init(rawValue:)),
              let createdAt = s.int64(base + 9), let updatedAt = s.int64(base + 10) else { return nil }
        return Session(id: id, kind: kind, range: TimeRange(start: start, end: end), origin: origin,
                       label: s.string(base + 5), deviceID: s.string(base + 6), detector: s.string(base + 7),
                       confidence: s.double(base + 8), createdAt: createdAt, updatedAt: updatedAt,
                       deleted: s.bool(base + 11) ?? false)
    }

    static let correctionColumns = "id, session_id, field, old_value, new_value, created_at"

    static func correction(_ s: SQLiteStatement, _ base: Int = 0) -> UserCorrection? {
        guard let id = s.int64(base), let field = s.string(base + 2), let createdAt = s.int64(base + 5) else {
            return nil
        }
        return UserCorrection(id: id, sessionID: s.int64(base + 1), field: field, oldValue: s.string(base + 3),
                              newValue: s.string(base + 4), createdAt: createdAt)
    }

    static let derivedColumns =
        "metric_id, spec_version, start_ms, end_ms, value, unit, availability, coverage, confidence, inputs_json, computed_at"

    static func derived(_ s: SQLiteStatement, _ base: Int = 0) -> DerivedMetricRecord? {
        guard let metricID = s.string(base), let specVersion = s.int(base + 1), let start = s.int64(base + 2),
              let end = s.int64(base + 3), let unit = s.string(base + 5), let availability = s.string(base + 6),
              let confidence = s.string(base + 8).flatMap(Confidence.init(rawValue:)),
              let inputs = s.string(base + 9), let computedAt = s.int64(base + 10) else { return nil }
        return DerivedMetricRecord(metricID: metricID, specVersion: specVersion,
                                   window: TimeRange(start: start, end: end), value: s.double(base + 4), unit: unit,
                                   availability: availability, coverage: s.double(base + 7), confidence: confidence,
                                   inputsJSON: inputs, computedAt: computedAt)
    }
}

/// The four measurement tables, with what paging, export and import need to know about each.
enum MeasurementTable: CaseIterable {
    case heartRate, beatInterval, motion, aux

    var name: String {
        switch self {
        case .heartRate: return "hr_sample"
        case .beatInterval: return "beat_interval"
        case .motion: return "motion_epoch"
        case .aux: return "aux_measurement"
        }
    }

    var columns: String {
        switch self {
        case .heartRate: return RowDecoder.heartRateColumns
        case .beatInterval: return RowDecoder.beatIntervalColumns
        case .motion: return RowDecoder.motionColumns
        case .aux: return RowDecoder.auxColumns
        }
    }

    /// Deduplicating INSERT for the table (see `StoreSQL`).
    var insertSQL: String {
        switch self {
        case .heartRate: return StoreSQL.insertHeartRate
        case .beatInterval: return StoreSQL.insertBeatInterval
        case .motion: return StoreSQL.insertMotion
        case .aux: return StoreSQL.insertAux
        }
    }
}

/// SQL shared by ingest and backup import. Inserts use `ON CONFLICT(<dedup key>) DO NOTHING`:
/// the INSERT-OR-IGNORE behaviour restricted to the dedup key, so an unexpected NOT NULL violation
/// still fails loudly instead of being silently counted as a duplicate.
enum StoreSQL {
    static let insertHeartRate = """
        INSERT INTO hr_sample (\(RowDecoder.heartRateColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (device_id, source, ts_ms) DO NOTHING
        """

    static let insertBeatInterval = """
        INSERT INTO beat_interval (\(RowDecoder.beatIntervalColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (device_id, source, record_key, idx) DO NOTHING
        """

    static let insertMotion = """
        INSERT INTO motion_epoch (\(RowDecoder.motionColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (device_id, source, ts_ms, epoch_ms) DO NOTHING
        """

    static let insertAux = """
        INSERT INTO aux_measurement (\(RowDecoder.auxColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (device_id, source, kind, ts_ms) DO NOTHING
        """

    static let insertProvenance = """
        INSERT INTO ingest_batch (\(RowDecoder.provenanceColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

    static let upsertCursor = """
        INSERT INTO sync_cursor (\(RowDecoder.cursorColumns))
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (device_id) DO UPDATE SET
            adapter_id = excluded.adapter_id,
            opaque = excluded.opaque,
            newest_record_ms = excluded.newest_record_ms,
            last_complete_ms = excluded.last_complete_ms,
            updated_at = excluded.updated_at
        """

    static let insertCorrection = """
        INSERT INTO user_correction (session_id, field, old_value, new_value, created_at)
        VALUES (?, ?, ?, ?, ?)
        """

    static let insertSession = """
        INSERT INTO session (kind, start_ms, end_ms, origin, label, device_id, detector, confidence,
                             created_at, updated_at, deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    static let insertDeviceIfAbsent = """
        INSERT INTO device (\(RowDecoder.deviceColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO NOTHING
        """

    /// `[start_ms, end_ms)` overlaps the query range `[?1, ?2)`; zero-length rows count as instants.
    /// Bind with `overlapArguments(_:)`.
    static let overlap = "start_ms < ? AND (end_ms > ? OR (end_ms = start_ms AND start_ms >= ?))"

    static func overlapArguments(_ range: TimeRange) -> [any SQLiteValueConvertible] {
        [range.end, range.start, range.start]
    }
}

/// Prepared measurement INSERTs, reused for every record of one transaction.
final class MeasurementWriter {
    private let db: SQLiteConnection
    private var statements: [MeasurementTable: SQLiteStatement] = [:]

    init(db: SQLiteConnection) {
        self.db = db
    }

    /// Each `insert` returns true when the row was stored, false when its dedup key already existed.
    func insert(_ s: HeartRateSample, batchID: Int64) throws -> Bool {
        try run(.heartRate, [s.deviceID, s.timestamp, s.bpm, s.source.rawValue, s.deviceTimeRaw, s.receivedAt,
                             s.clockOffsetMillis, s.quality.rawValue, batchID])
    }

    func insert(_ b: BeatInterval, batchID: Int64) throws -> Bool {
        try run(.beatInterval, [b.deviceID, b.timestamp, b.intervalMillis, b.source.rawValue, b.recordKey,
                                b.indexInRecord, b.receivedAt, b.timingBasis.rawValue, b.quality.rawValue, batchID])
    }

    func insert(_ m: MotionEpoch, batchID: Int64) throws -> Bool {
        try run(.motion, [m.deviceID, m.timestamp, m.epochMillis, m.activity, m.sampleCount, m.source.rawValue,
                          m.quality.rawValue, batchID])
    }

    func insert(_ a: AuxMeasurement, batchID: Int64) throws -> Bool {
        try run(.aux, [a.deviceID, a.timestamp, a.kind.rawValue, a.value, a.source.rawValue, a.validated,
                       a.quality.rawValue, batchID])
    }

    private func run(_ table: MeasurementTable, _ values: [any SQLiteValueConvertible]) throws -> Bool {
        let statement: SQLiteStatement
        if let cached = statements[table] {
            statement = cached
            statement.reset()
        } else {
            statement = try db.prepare(table.insertSQL)
            statements[table] = statement
        }
        try statement.bind(values: values)
        try statement.step()
        return db.changes > 0
    }
}
