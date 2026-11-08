import Foundation
import FormaCore

/// Forma's on-device database: measurements with provenance, sync state, sessions and their
/// correction history, a cache of derived metrics, and settings, in one SQLite file (WAL mode).
/// Nothing here touches the network.
///
/// ## Thread safety
/// Every public method may be called from any thread. All access to the single SQLite connection
/// is serialized through one recursive lock that is held for the whole call, so each call sees and
/// leaves a consistent database. Long-running exports and imports take the lock once per page or
/// chunk, so ingest can interleave with them. Because no mutable state is touched outside that
/// lock, the class is declared `@unchecked Sendable`. Calls block while they wait for the lock, so
/// run long ones (export, import, deleteAllData) off the main thread. Use one `FormaStore` per
/// database file per process: retention bookkeeping is cached per instance.
///
/// ## Honesty rules
/// Values are stored exactly as delivered (flags are data, implausible values are flagged upstream,
/// never altered here). Readers return nil for missing values, never 0; rows that cannot be decoded
/// are skipped rather than completed with invented values.
public final class FormaStore: IngestSink, @unchecked Sendable {
    /// Newest schema version this build reads and writes (`PRAGMA user_version`).
    public static let schemaVersion: Int = Migrations.latestVersion

    /// Connection-history rows kept before the oldest are trimmed (10 % at a time).
    public static let defaultConnectionEventLimit = 20_000

    /// Database file path, or nil for an in-memory store.
    public let path: String?
    /// Bounds applied to diagnostics raw-frame capture.
    public let rawFrameRetention: RawFrameRetention
    /// Source of "now" for correction timestamps, retention and backup headers.
    let timeSource: any TimeSource

    private let lock = NSRecursiveLock()
    private var connection: SQLiteConnection?
    private var rawCaptureEnabledCache: Bool?
    private var rawFrameUsageCache: RawFrameUsage?
    private var connectionEventCountCache: Int?
    /// Overridable by tests; read under the lock.
    var connectionEventLimit = FormaStore.defaultConnectionEventLimit

    private struct RawFrameUsage {
        var frames: Int
        var bytes: Int
    }

    /// Opens (creating and migrating if needed) the store.
    /// - Parameters:
    ///   - path: Database file path (parent directories are created), or nil for an in-memory store.
    ///   - timeSource: Clock for stored "now" values; inject `ManualTimeSource` in tests and replays.
    ///   - rawFrameRetention: Bounds for diagnostics raw-frame capture.
    /// - Throws: `StoreError.schemaTooNew` / `.notAFormaDatabase` for files this build must not touch,
    ///   `StoreError.fileError`, or `SQLiteError`.
    public init(path: String?, timeSource: any TimeSource = SystemTimeSource(),
                rawFrameRetention: RawFrameRetention = .default) throws {
        let databasePath: String
        if let path {
            guard !path.isEmpty else { throw StoreError.invalidArgument("database path is empty") }
            databasePath = path
            if path != SQLiteConnection.inMemoryPath {
                let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    throw StoreError.fileError("cannot create directory \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
                }
            }
        } else {
            databasePath = SQLiteConnection.inMemoryPath
        }
        self.path = path
        self.timeSource = timeSource
        self.rawFrameRetention = rawFrameRetention
        let db = try SQLiteConnection(path: databasePath)
        try Migrations.migrate(db)
        connection = db
        try enforceRawFrameRetention()
    }

    deinit {
        connection?.close()
    }

    /// Closes the database. Later calls throw `StoreError.closed`. Idempotent; also done on deinit.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        connection?.close()
        connection = nil
    }

    /// False after `close()`.
    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection?.isOpen ?? false
    }

    /// Runs `body` with the connection while holding the store lock.
    @discardableResult
    func locked<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db = connection, db.isOpen else { throw StoreError.closed }
        return try body(db)
    }

    /// Test hook: direct access to the connection under the store lock.
    @discardableResult
    func withConnectionForTesting<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try locked(body)
    }

    // MARK: - IngestSink

    /// Persists a batch atomically, in ONE transaction: an `ingest_batch` provenance row, every record
    /// (stamped with that batch id; records whose dedup key already exists are skipped and counted as
    /// duplicates), and the cursor if one is given. If anything fails, everything is rolled back and
    /// the error rethrown, so a history acknowledgement can safely depend on this returning.
    /// - Throws: `StoreError.invalidRecord` (before writing anything) for an empty or mismatched
    ///   device ID, a non-finite number, or another structurally impossible value; `SQLiteError`.
    public func ingest(_ batch: IngestBatch) throws -> IngestResult {
        try RecordValidator.validate(batch)
        return try locked { db in
            try db.transaction {
                let batchID = try Self.insertProvenance(batch.provenance, db: db)
                let writer = MeasurementWriter(db: db)
                var inserted = 0
                var duplicates = 0
                func tally(_ stored: Bool) {
                    if stored { inserted += 1 } else { duplicates += 1 }
                }
                for sample in batch.heartRates { tally(try writer.insert(sample, batchID: batchID)) }
                for interval in batch.beatIntervals { tally(try writer.insert(interval, batchID: batchID)) }
                for epoch in batch.motion { tally(try writer.insert(epoch, batchID: batchID)) }
                for measurement in batch.aux { tally(try writer.insert(measurement, batchID: batchID)) }
                if let cursor = batch.cursor {
                    try Self.upsertCursor(cursor, db: db)
                }
                return IngestResult(batchID: batchID, inserted: inserted, duplicates: duplicates)
            }
        }
    }

    /// The device's stored history position, or nil before its first cursor-carrying batch.
    public func syncCursor(deviceID: String) throws -> SyncCursor? {
        try locked { db in
            try db.query("SELECT \(RowDecoder.cursorColumns) FROM sync_cursor WHERE device_id = ?", [deviceID]) {
                RowDecoder.cursor($0)
            }.first
        }
    }

    /// Inserts or updates a device. On update, values the new record does not know (nil firmware or
    /// hardware, `.unknown` family) keep what was stored, `firstSeen` keeps the earliest value and
    /// `lastConnected` the latest.
    public func upsertDevice(_ device: DeviceRecord) throws {
        try RecordValidator.validate(device)
        try locked { db in
            try db.run("""
                INSERT INTO device (\(RowDecoder.deviceColumns)) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    family = CASE WHEN excluded.family = ? THEN device.family ELSE excluded.family END,
                    name = excluded.name,
                    firmware = COALESCE(excluded.firmware, device.firmware),
                    hardware = COALESCE(excluded.hardware, device.hardware),
                    first_seen = MIN(device.first_seen, excluded.first_seen),
                    last_connected = CASE
                        WHEN device.last_connected IS NULL THEN excluded.last_connected
                        WHEN excluded.last_connected IS NULL THEN device.last_connected
                        ELSE MAX(device.last_connected, excluded.last_connected) END
                """, [device.id, device.family.rawValue, device.name, device.firmwareVersion, device.hardwareRevision,
                      device.firstSeen, device.lastConnected, DeviceFamily.unknown.rawValue])
        }
    }

    /// Appends a connection-history event. The table keeps at most `defaultConnectionEventLimit`
    /// rows; beyond that the oldest 10 % are removed.
    public func recordConnectionEvent(_ event: ConnectionEvent) throws {
        try locked { db in
            do {
                try db.transaction {
                    let count = try connectionEventCountCache ?? Self.countRows(db, "connection_event")
                    try db.run("INSERT INTO connection_event (\(RowDecoder.connectionEventColumns)) VALUES (?, ?, ?, ?)",
                               [event.deviceID, event.timestamp, event.kind.rawValue, event.detail])
                    connectionEventCountCache = count + 1
                    let limit = max(1, connectionEventLimit)
                    if count + 1 > limit {
                        let keep = limit - limit / 10
                        try db.run("DELETE FROM connection_event WHERE id IN (SELECT id FROM connection_event ORDER BY id LIMIT ?)",
                                   [count + 1 - keep])
                        connectionEventCountCache = try Self.countRows(db, "connection_event")
                    }
                }
            } catch {
                connectionEventCountCache = nil
                throw error
            }
        }
    }

    /// Stores raw evidence only while raw capture is enabled (`setRawCaptureEnabled`, default off),
    /// then enforces `rawFrameRetention`. A frame larger than `maxTotalBytes` is not stored (it could
    /// never fit within the bound); payload bytes are never truncated or altered.
    public func recordRawFrame(_ frame: RawFrameRecord) throws {
        try locked { db in
            guard try loadRawCaptureEnabled(db), frame.bytes.count <= rawFrameRetention.maxTotalBytes else { return }
            do {
                try db.transaction {
                    var usage = try currentRawFrameUsage(db)
                    try db.run("INSERT INTO raw_frame (\(RowDecoder.rawFrameColumns)) VALUES (?, ?, ?, ?, ?)",
                               [frame.deviceID, frame.receivedAt, frame.characteristic, frame.bytes, frame.parseStatus])
                    usage.frames += 1
                    usage.bytes += frame.bytes.count
                    rawFrameUsageCache = usage
                    try enforceRawFrameRetention(db, now: timeSource.now())
                }
            } catch {
                rawFrameUsageCache = nil
                throw error
            }
        }
    }

    /// Records the start of a sync attempt and returns its id (the `id` in `run` is ignored).
    public func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 {
        try RecordValidator.identifier(run.deviceID, "syncRun.deviceID")
        return try locked { db in
            try db.run("""
                INSERT INTO sync_run (device_id, started_at, ended_at, status, batches, records_inserted, duplicates,
                                      malformed_frames, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [run.deviceID, run.startedAt, run.endedAt, run.status.rawValue, run.batches, run.recordsInserted,
                      run.duplicates, run.malformedFrames, run.note])
            return db.lastInsertRowID
        }
    }

    /// Stores the outcome of a sync attempt started with `beginSyncRun` (`run.id` is required).
    /// Updates end time, status, counters and note.
    public func finishSyncRun(_ run: SyncRunRecord) throws {
        guard let id = run.id else {
            throw StoreError.invalidArgument("finishSyncRun requires the id returned by beginSyncRun")
        }
        try locked { db in
            let changed = try db.run("""
                UPDATE sync_run SET ended_at = ?, status = ?, batches = ?, records_inserted = ?, duplicates = ?,
                                    malformed_frames = ?, note = ?
                WHERE id = ?
                """, [run.endedAt, run.status.rawValue, run.batches, run.recordsInserted, run.duplicates,
                      run.malformedFrames, run.note, id])
            if changed == 0 { throw StoreError.notFound("sync run \(id)") }
        }
    }

    // MARK: - Provenance and cursors

    /// The provenance stored for an ingest batch (`batchID` on every measurement).
    public func provenance(batchID: Int64) throws -> Provenance? {
        try locked { db in
            try db.query("SELECT \(RowDecoder.provenanceColumns) FROM ingest_batch WHERE id = ?", [batchID]) {
                RowDecoder.provenance($0)
            }.first
        }
    }

    /// All stored sync cursors, by device ID.
    public func syncCursors() throws -> [SyncCursor] {
        try locked { db in
            try db.query("SELECT \(RowDecoder.cursorColumns) FROM sync_cursor ORDER BY device_id") { RowDecoder.cursor($0) }
        }
    }

    /// Forgets a device's sync position, so its next history transfer starts from what the band offers.
    /// Returns true when a cursor existed. Already stored records are kept (re-downloads dedup).
    @discardableResult
    public func deleteSyncCursor(deviceID: String) throws -> Bool {
        try locked { db in try db.run("DELETE FROM sync_cursor WHERE device_id = ?", [deviceID]) > 0 }
    }

    static func insertProvenance(_ provenance: Provenance, db: SQLiteConnection) throws -> Int64 {
        try db.run(StoreSQL.insertProvenance,
                   [provenance.deviceID, provenance.adapterID, provenance.parserVersion, provenance.firmwareVersion,
                    provenance.source.rawValue, provenance.syncRunID, provenance.createdAt, provenance.note])
        return db.lastInsertRowID
    }

    static func upsertCursor(_ cursor: SyncCursor, db: SQLiteConnection) throws {
        try db.run(StoreSQL.upsertCursor,
                   [cursor.deviceID, cursor.adapterID, cursor.opaque, cursor.newestPersistedRecordTime,
                    cursor.lastCompleteSyncAt, cursor.updatedAt])
    }

    static func countRows(_ db: SQLiteConnection, _ table: String) throws -> Int {
        Int(try db.scalarInt64("SELECT COUNT(*) FROM \(table)") ?? 0)
    }

    // MARK: - Raw frame capture

    /// Whether raw BLE frames are being kept for diagnostics (stored setting, default false).
    public func rawCaptureEnabled() throws -> Bool {
        try locked { db in try loadRawCaptureEnabled(db) }
    }

    /// Turns diagnostics raw-frame capture on or off. Turning it off keeps already captured frames
    /// (subject to retention); use `deleteRawFrames()` to discard them.
    public func setRawCaptureEnabled(_ enabled: Bool) throws {
        try setSetting(enabled ? "true" : "false", forKey: StoreSettingKey.rawCaptureEnabled)
    }

    /// Applies `rawFrameRetention` now (also done on open and after every captured frame), so frames
    /// age out even while nothing new is captured.
    public func enforceRawFrameRetention() throws {
        try locked { db in
            do {
                try db.transaction { try enforceRawFrameRetention(db, now: timeSource.now()) }
            } catch {
                rawFrameUsageCache = nil
                throw error
            }
        }
    }

    /// Deletes every captured raw frame; returns how many were removed.
    @discardableResult
    public func deleteRawFrames() throws -> Int {
        try locked { db in
            rawFrameUsageCache = nil
            return try db.run("DELETE FROM raw_frame")
        }
    }

    /// The most recently received frames, newest first.
    public func rawFrames(limit: Int = 500) throws -> [RawFrameRecord] {
        try locked { db in
            try db.query("SELECT \(RowDecoder.rawFrameColumns) FROM raw_frame ORDER BY received_at DESC, id DESC LIMIT ?",
                         [max(0, limit)]) { RowDecoder.rawFrame($0) }
        }
    }

    private func loadRawCaptureEnabled(_ db: SQLiteConnection) throws -> Bool {
        if let cached = rawCaptureEnabledCache { return cached }
        let enabled = try db.scalarText("SELECT value FROM setting WHERE key = ?",
                                        [StoreSettingKey.rawCaptureEnabled]) == "true"
        rawCaptureEnabledCache = enabled
        return enabled
    }

    private func currentRawFrameUsage(_ db: SQLiteConnection) throws -> RawFrameUsage {
        if let cached = rawFrameUsageCache { return cached }
        let statement = try db.prepare("SELECT COUNT(*), COALESCE(SUM(length(bytes)), 0) FROM raw_frame")
        guard try statement.step() == .row else { return RawFrameUsage(frames: 0, bytes: 0) }
        let usage = RawFrameUsage(frames: statement.int(0) ?? 0, bytes: statement.int(1) ?? 0)
        rawFrameUsageCache = usage
        return usage
    }

    /// Deletes frames older than the age bound, then — if the count or byte bound is exceeded — the
    /// oldest frames (by insertion order) until both are back under 90 % of their bound. The newest
    /// frame is always kept; it fits on its own because oversized frames are never stored.
    private func enforceRawFrameRetention(_ db: SQLiteConnection, now: EpochMillis) throws {
        let policy = rawFrameRetention
        let (cutoff, overflow) = now.subtractingReportingOverflow(policy.maxAgeMillis)
        if !overflow, try db.run("DELETE FROM raw_frame WHERE received_at < ?", [cutoff]) > 0 {
            rawFrameUsageCache = nil
        }
        let usage = try currentRawFrameUsage(db)
        guard usage.frames > policy.maxFrames || usage.bytes > policy.maxTotalBytes else { return }
        let targetFrames = policy.maxFrames - policy.maxFrames / 10
        let targetBytes = policy.maxTotalBytes - policy.maxTotalBytes / 10
        var frames = usage.frames
        var bytes = usage.bytes
        var lastDeletedID: Int64?
        let oldest = try db.prepare("SELECT id, length(bytes) FROM raw_frame ORDER BY id")
        while frames > 1, frames > targetFrames || bytes > targetBytes, try oldest.step() == .row {
            guard let id = oldest.int64(0) else { break }
            lastDeletedID = id
            frames -= 1
            bytes -= oldest.int(1) ?? 0
        }
        oldest.finalize()
        if let lastDeletedID {
            try db.run("DELETE FROM raw_frame WHERE id <= ?", [lastDeletedID])
        }
        rawFrameUsageCache = nil
        _ = try currentRawFrameUsage(db)
    }

    // MARK: - Settings

    /// The stored string for `key`, or nil.
    public func setting(forKey key: String) throws -> String? {
        try locked { db in try db.scalarText("SELECT value FROM setting WHERE key = ?", [key]) }
    }

    /// Stores `value` under `key` (replacing any previous value).
    public func setSetting(_ value: String, forKey key: String) throws {
        try Self.validateSettingKey(key)
        try locked { db in
            try db.run("INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                       [key, value])
            if key == StoreSettingKey.rawCaptureEnabled { rawCaptureEnabledCache = nil }
        }
    }

    /// Removes `key`. Returns true when it existed.
    @discardableResult
    public func removeSetting(forKey key: String) throws -> Bool {
        try locked { db in
            if key == StoreSettingKey.rawCaptureEnabled { rawCaptureEnabledCache = nil }
            return try db.run("DELETE FROM setting WHERE key = ?", [key]) > 0
        }
    }

    /// Every stored setting.
    public func allSettings() throws -> [String: String] {
        try locked { db in
            var settings: [String: String] = [:]
            for (key, value) in try db.query("SELECT key, value FROM setting", [], { s -> (String, String)? in
                guard let key = s.string(0), let value = s.string(1) else { return nil }
                return (key, value)
            }) {
                settings[key] = value
            }
            return settings
        }
    }

    /// Decodes the JSON stored under `key`; nil when absent.
    /// - Throws: `StoreError.corruptSetting` when the stored text is not valid JSON for `T`.
    public func codableSetting<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let text = try setting(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw StoreError.corruptSetting(key: key, detail: String(describing: error))
        }
    }

    /// Stores `value` as JSON (sorted keys, so equal values produce equal text).
    public func setCodableSetting<T: Encodable>(_ value: T, forKey key: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try setSetting(String(decoding: data, as: UTF8.self), forKey: key)
    }

    /// The stored user profile (key `user_profile`), or nil when none was saved.
    public func userProfile() throws -> UserProfile? {
        try codableSetting(UserProfile.self, forKey: StoreSettingKey.userProfile)
    }

    /// Stores the user profile as JSON under `user_profile`, replacing any previous one.
    public func setUserProfile(_ profile: UserProfile) throws {
        try setCodableSetting(profile, forKey: StoreSettingKey.userProfile)
    }

    static func validateSettingKey(_ key: String) throws {
        if key.isEmpty { throw StoreError.invalidArgument("setting key is empty") }
        if key.utf8.count > RecordValidator.maxIdentifierBytes {
            throw StoreError.invalidArgument("setting key is longer than \(RecordValidator.maxIdentifierBytes) bytes")
        }
    }

    // MARK: - Deletion

    /// Deletes every row of every table (settings too unless `keepSettings`) in one transaction, then
    /// rebuilds the file with VACUUM and truncates the WAL so deleted data does not linger in free
    /// pages or the log.
    public func deleteAllData(keepSettings: Bool = false) throws {
        try locked { db in
            defer {
                rawCaptureEnabledCache = nil
                rawFrameUsageCache = nil
                connectionEventCountCache = nil
            }
            try db.transaction {
                for table in Schema.deletionOrder where !(keepSettings && table == "setting") {
                    try db.execute("DELETE FROM \(table)")
                }
            }
            try db.execute("VACUUM")
            if !db.isInMemory {
                try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
    }

    /// Removes a database file and its `-wal`, `-shm` and `-journal` companions. Close every store
    /// using the file first. Missing files are not an error.
    public static func destroyDatabaseFiles(at path: String) throws {
        guard !path.isEmpty, path != SQLiteConnection.inMemoryPath else { return }
        let fileManager = FileManager.default
        for file in [path, path + "-wal", path + "-shm", path + "-journal"] where fileManager.fileExists(atPath: file) {
            do {
                try fileManager.removeItem(atPath: file)
            } catch {
                throw StoreError.fileError("cannot delete \(file): \(error.localizedDescription)")
            }
        }
    }
}
