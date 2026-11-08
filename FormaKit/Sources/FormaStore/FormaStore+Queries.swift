import Foundation
import FormaCore

/// Read access. Measurement queries cover the half-open range `[range.start, range.end)` of
/// normalized timestamps and return records sorted by time (ties broken by device, then source).
/// Log-style queries (connection events, sync runs, raw frames) return the newest `limit` rows,
/// newest first.
extension FormaStore {
    // MARK: Measurements

    /// Heart-rate samples in `range`, optionally limited to one device and/or a set of sources
    /// (an empty set matches nothing).
    public func heartRates(in range: TimeRange, deviceID: String? = nil,
                           sources: Set<MeasurementSource>? = nil) throws -> [HeartRateSample] {
        if let sources, sources.isEmpty { return [] }
        let (whereClause, values) = Self.measurementFilter(range: range, deviceID: deviceID, sources: sources)
        return try locked { db in
            try db.query("SELECT \(RowDecoder.heartRateColumns) FROM hr_sample WHERE \(whereClause) ORDER BY ts_ms, device_id, source",
                         values) { RowDecoder.heartRate($0) }
        }
    }

    /// Device-emitted beat-to-beat intervals in `range` (by the time of the beat closing each interval).
    public func beatIntervals(in range: TimeRange, deviceID: String? = nil,
                              sources: Set<MeasurementSource>? = nil) throws -> [BeatInterval] {
        if let sources, sources.isEmpty { return [] }
        let (whereClause, values) = Self.measurementFilter(range: range, deviceID: deviceID, sources: sources)
        return try locked { db in
            try db.query("""
                SELECT \(RowDecoder.beatIntervalColumns) FROM beat_interval WHERE \(whereClause)
                ORDER BY ts_ms, device_id, source, record_key, idx
                """, values) { RowDecoder.beatInterval($0) }
        }
    }

    /// Motion epochs whose start time lies in `range`.
    public func motion(in range: TimeRange, deviceID: String? = nil,
                       sources: Set<MeasurementSource>? = nil) throws -> [MotionEpoch] {
        if let sources, sources.isEmpty { return [] }
        let (whereClause, values) = Self.measurementFilter(range: range, deviceID: deviceID, sources: sources)
        return try locked { db in
            try db.query("""
                SELECT \(RowDecoder.motionColumns) FROM motion_epoch WHERE \(whereClause)
                ORDER BY ts_ms, device_id, source, epoch_ms
                """, values) { RowDecoder.motion($0) }
        }
    }

    /// Auxiliary measurements in `range`, optionally limited to some kinds (an empty set matches
    /// nothing) and one device. Includes unvalidated values: check `validated` before showing them.
    public func aux(in range: TimeRange, kinds: Set<AuxKind>? = nil,
                    deviceID: String? = nil) throws -> [AuxMeasurement] {
        if let kinds, kinds.isEmpty { return [] }
        var (whereClause, values) = Self.measurementFilter(range: range, deviceID: deviceID, sources: nil)
        if let kinds {
            let names = kinds.map(\.rawValue).sorted()
            whereClause += " AND kind IN (\(Self.placeholders(names.count)))"
            values += names.map { $0 as any SQLiteValueConvertible }
        }
        return try locked { db in
            try db.query("""
                SELECT \(RowDecoder.auxColumns) FROM aux_measurement WHERE \(whereClause)
                ORDER BY ts_ms, kind, device_id, source
                """, values) { RowDecoder.aux($0) }
        }
    }

    /// Newest measurement timestamp across all four measurement tables (optionally for one device);
    /// nil when there is none.
    public func newestSampleTime(deviceID: String? = nil) throws -> EpochMillis? {
        try locked { db in
            var newest: EpochMillis?
            for table in Schema.measurementTables {
                let value: Int64?
                if let deviceID {
                    value = try db.scalarInt64("SELECT MAX(ts_ms) FROM \(table) WHERE device_id = ?", [deviceID])
                } else {
                    value = try db.scalarInt64("SELECT MAX(ts_ms) FROM \(table)")
                }
                if let value { newest = max(newest ?? value, value) }
            }
            return newest
        }
    }

    /// The smallest range `[oldest, newest + 1 ms)` containing every stored measurement; nil when empty.
    /// Timestamps are reported as stored. Backup import only admits `backupTimeWindow`, but `ingest`
    /// stores whatever the sync engine delivers, so callers doing arithmetic on the bounds of data
    /// they did not validate should use overflow-checked operations.
    public func dataBounds() throws -> TimeRange? {
        try locked { db in
            var oldest: EpochMillis?
            var newest: EpochMillis?
            for table in Schema.measurementTables {
                // Separate MIN and MAX queries: each is a single index probe, together they would scan.
                if let value = try db.scalarInt64("SELECT MIN(ts_ms) FROM \(table)") { oldest = min(oldest ?? value, value) }
                if let value = try db.scalarInt64("SELECT MAX(ts_ms) FROM \(table)") { newest = max(newest ?? value, value) }
            }
            guard let oldest, let newest else { return nil }
            let (end, overflow) = newest.addingReportingOverflow(1)
            return TimeRange(start: oldest, end: overflow ? newest : end)
        }
    }

    /// Row count of every table, for the diagnostics screen.
    public func tableCounts() throws -> [String: Int] {
        try locked { db in
            var counts: [String: Int] = [:]
            for table in Schema.allTables {
                counts[table] = try Self.countRows(db, table)
            }
            return counts
        }
    }

    // MARK: Devices, connection history, sync runs

    /// All known devices, in the order they were first seen.
    public func devices() throws -> [DeviceRecord] {
        try locked { db in
            try db.query("SELECT \(RowDecoder.deviceColumns) FROM device ORDER BY first_seen, id") { RowDecoder.device($0) }
        }
    }

    /// The device with this local identifier, or nil.
    public func device(id: String) throws -> DeviceRecord? {
        try locked { db in
            try db.query("SELECT \(RowDecoder.deviceColumns) FROM device WHERE id = ?", [id]) { RowDecoder.device($0) }.first
        }
    }

    /// The newest `limit` connection events (optionally for one device), newest first.
    public func connectionEvents(limit: Int = 200, deviceID: String? = nil) throws -> [ConnectionEvent] {
        var sql = "SELECT \(RowDecoder.connectionEventColumns) FROM connection_event"
        var values: [any SQLiteValueConvertible] = []
        if let deviceID {
            sql += " WHERE device_id = ?"
            values.append(deviceID)
        }
        sql += " ORDER BY ts_ms DESC, id DESC LIMIT ?"
        values.append(max(0, limit))
        return try locked { db in try db.query(sql, values) { RowDecoder.connectionEvent($0) } }
    }

    /// The newest `limit` sync runs (optionally for one device), newest first.
    public func syncRuns(limit: Int = 50, deviceID: String? = nil) throws -> [SyncRunRecord] {
        var sql = "SELECT \(RowDecoder.syncRunColumns) FROM sync_run"
        var values: [any SQLiteValueConvertible] = []
        if let deviceID {
            sql += " WHERE device_id = ?"
            values.append(deviceID)
        }
        sql += " ORDER BY started_at DESC, id DESC LIMIT ?"
        values.append(max(0, limit))
        return try locked { db in try db.query(sql, values) { RowDecoder.syncRun($0) } }
    }

    /// One sync run by the id `beginSyncRun` returned, or nil.
    public func syncRun(id: Int64) throws -> SyncRunRecord? {
        try locked { db in
            try db.query("SELECT \(RowDecoder.syncRunColumns) FROM sync_run WHERE id = ?", [id]) { RowDecoder.syncRun($0) }.first
        }
    }

    // MARK: Paging (exports)

    /// The keyset-pagination query `forEachPage` runs: rows after `(ts_ms, rowid)` = (?2, ?3) with
    /// `ts_ms >= ?1` (and `ts_ms < ?4` with a range), in `(ts_ms, rowid)` order, `LIMIT` last. The
    /// `(ts_ms)` index delivers exactly that order, so no page ever needs a sort.
    ///
    /// With `withOrigin`, every row is followed by the `adapter_id` and `firmware` of the `ingest_batch`
    /// that stored it (NULL when the batch is unknown), looked up by its primary key.
    static func pageSQL(_ table: MeasurementTable, hasRange: Bool, withOrigin: Bool = false) -> String {
        guard withOrigin else {
            var sql = "SELECT rowid, ts_ms, \(table.columns) FROM \(table.name) WHERE ts_ms >= ? AND (ts_ms > ? OR rowid > ?)"
            if hasRange { sql += " AND ts_ms < ?" }
            return sql + " ORDER BY ts_ms, rowid LIMIT ?"
        }
        let columns = table.columns.split(separator: ",")
            .map { "m." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        var sql = "SELECT m.rowid, m.ts_ms, \(columns), b.adapter_id, b.firmware FROM \(table.name) AS m "
            + "LEFT JOIN ingest_batch AS b ON b.id = m.batch_id WHERE m.ts_ms >= ? AND (m.ts_ms > ? OR m.rowid > ?)"
        if hasRange { sql += " AND m.ts_ms < ?" }
        return sql + " ORDER BY m.ts_ms, m.rowid LIMIT ?"
    }

    /// Streams a measurement table in `(ts_ms, rowid)` order, `pageSize` rows per lock acquisition,
    /// and hands each decoded page to `body` with the lock released (keyset pagination, so ingest
    /// can interleave with a long export). Rows written concurrently behind the read position are
    /// not included: the result is not a point-in-time snapshot. With `withOrigin`, `decode` also finds
    /// the row's batch `adapter_id` and `firmware` after the table's columns (see `pageSQL`).
    /// - Throws: `CancellationError` (checked before every page) when the calling task is cancelled.
    func forEachPage<Row>(_ table: MeasurementTable, range: TimeRange?, pageSize: Int = 4_096, withOrigin: Bool = false,
                          decode: (SQLiteStatement, Int) -> Row?, body: ([Row]) throws -> Void) throws {
        let sql = Self.pageSQL(table, hasRange: range != nil, withOrigin: withOrigin)
        let limit = max(1, pageSize)
        var afterTimestamp = range?.start ?? Int64.min
        var afterRowID = Int64.min
        while true {
            try Task.checkCancellation()
            var fetched = 0
            var lastKey: (timestamp: Int64, rowID: Int64)?
            let page: [Row] = try locked { db in
                let statement = try db.prepare(sql)
                var values: [any SQLiteValueConvertible] = [afterTimestamp, afterTimestamp, afterRowID]
                if let range { values.append(range.end) }
                values.append(limit)
                try statement.bind(values: values)
                var rows: [Row] = []
                while try statement.step() == .row {
                    fetched += 1
                    if let rowID = statement.int64(0), let timestamp = statement.int64(1) {
                        lastKey = (timestamp, rowID)
                    }
                    if let row = decode(statement, 2) { rows.append(row) }
                }
                return rows
            }
            if !page.isEmpty { try body(page) }
            guard fetched == limit, let lastKey else { return }
            afterTimestamp = lastKey.timestamp
            afterRowID = lastKey.rowID
        }
    }

    // MARK: Helpers

    static func measurementFilter(range: TimeRange, deviceID: String?,
                                  sources: Set<MeasurementSource>?) -> (String, [any SQLiteValueConvertible]) {
        var clause = "ts_ms >= ? AND ts_ms < ?"
        var values: [any SQLiteValueConvertible] = [range.start, range.end]
        if let deviceID {
            clause += " AND device_id = ?"
            values.append(deviceID)
        }
        if let sources {
            let codes = sources.map(\.rawValue).sorted()
            clause += " AND source IN (\(placeholders(codes.count)))"
            values += codes.map { $0 as any SQLiteValueConvertible }
        }
        return (clause, values)
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }
}
