import Foundation
import FormaCore

/// Record kinds in a Forma backup (the `type` field of each NDJSON line).
public enum BackupRecordType: String, CaseIterable, Sendable, Hashable, Codable {
    case device, hr, rr, motion, aux, session, correction, setting, cursor
}

/// Result of `FormaStore.exportBackup(to:)`.
public struct BackupSummary: Hashable, Sendable {
    /// The written backup file.
    public var fileURL: URL
    /// Backup format version written in the header (`FormaStore.backupFormatVersion`).
    public var formatVersion: Int
    /// Database schema version of the exporting store.
    public var schemaVersion: Int
    /// Export time from the store's time source, epoch milliseconds (UTC).
    public var exportedAt: EpochMillis
    /// Records written per type (the header line is not counted).
    public var counts: [BackupRecordType: Int]
    /// Lines written, including the header.
    public var lineCount: Int
    /// File size in bytes.
    public var byteCount: Int64
    /// `[oldest, newest + 1 ms)` over the exported measurement timestamps; nil when there were none.
    public var measurementRange: TimeRange?

    /// Records written, all types together.
    public var totalRecords: Int { counts.values.reduce(0, +) }
}

/// Result of `FormaStore.importBackup(from:)`.
public struct ImportReport: Hashable, Sendable {
    /// At most this many error messages are kept in `errors`.
    public static let maxRecordedErrors = 20
    /// At most this many cursors (one per device) are kept in `cursorsNotApplied`.
    public static let maxReportedCursors = 32

    /// Name of the imported file (also stored as the note of the import's `ingest_batch` rows).
    public var fileName: String
    /// Backup format version read from the header.
    public var formatVersion: Int
    /// Schema version of the store that wrote the backup (informational).
    public var sourceSchemaVersion: Int?
    /// Export time from the header, epoch milliseconds (UTC), if present.
    public var exportedAt: EpochMillis?
    /// `ingest_batch` rows holding the newly stored measurements: one per device and original adapter
    /// and firmware (source `.backupImport`, note = file name; see `importBackup`). A batch is created
    /// only for such a group with at least one newly stored measurement, so re-importing a file adds no
    /// rows at all.
    public var batchIDs: [Int64]
    /// Records newly stored, per type.
    public var inserted: [BackupRecordType: Int]
    /// Valid records that were already present (same dedup key, or the same setting value), per type.
    public var duplicates: [BackupRecordType: Int]
    /// Valid records deliberately not applied, per type: every sync cursor (see `importBackup`),
    /// settings that only describe the exporting phone, settings the caller withholds
    /// (`settingsWithheld`), and settings whose key already holds a different value on this phone (the
    /// local value is kept).
    public var notApplied: [BackupRecordType: Int]
    /// Settings lines the caller's `withholdingSettings` rule kept out of this store (also counted in
    /// `notApplied[.setting]`). They are never written, not even for a moment.
    public var settingsWithheld: Int
    /// Lines skipped because they could not be read or failed validation.
    public var invalidLines: Int
    /// Reasons for the `maxRecordedErrors` lowest-numbered invalid lines, as "line N: reason", in line order.
    public var errors: [String]
    /// Smallest range covering every newly stored measurement and session (`[oldest, newest + 1 ms)`);
    /// derived values inside it should be recomputed. Nil when nothing new was stored. Always inside
    /// `FormaStore.backupTimeWindow`.
    public var importedRange: TimeRange?
    /// Sync cursors found in the backup, for information only (never applied to sync state): the most
    /// recently updated cursor of each device, for at most `maxReportedCursors` devices, so a hostile
    /// file cannot make the report grow without bound. `notApplied[.cursor]` counts every cursor line.
    public var cursorsNotApplied: [SyncCursor]

    /// Records newly stored, all types together.
    public var totalInserted: Int { inserted.values.reduce(0, +) }
    /// Valid records already present, all types together.
    public var totalDuplicates: Int { duplicates.values.reduce(0, +) }
}

/// Versioned NDJSON backup.
///
/// Line 1 is the header `{"format":"forma-backup","formatVersion":1,"schemaVersion":N,"exportedAt":ms,"app":"Forma"}`.
/// Every following line is one record `{"type":"device"|"hr"|"rr"|"motion"|"aux"|"session"|"correction"|"setting"|"cursor","data":{...}}`
/// whose `data` keys are the database column names (snake_case; timestamps in epoch ms UTC; NULL as
/// `null`; blobs as base64). Measurement lines (`hr`, `rr`, `motion`, `aux`) also carry `adapter_id`
/// and `firmware` from the `ingest_batch` that stored them (null when unknown; absent in files written
/// by earlier builds, which readers of format 1 accept), so restored band history keeps the adapter and
/// firmware its field-validation verdict is keyed by. Not included: derived metrics (recomputable), raw
/// frames, connection history and sync runs (device-local diagnostics), and the batches themselves
/// (parser version, sync run, creation time): restored measurements point to backup-import batches.
extension FormaStore {
    /// Value of the header's `format` field.
    public static let backupFormatName = "forma-backup"
    /// Newest backup format this build writes and reads.
    public static let backupFormatVersion = 1
    /// Longest accepted backup line (1 MiB). Longer lines are skipped and reported, never loaded.
    public static let maxBackupLineBytes = 1_048_576
    /// Timeline timestamps a backup may contain: `[1970-01-01T00:00:00.000Z, 10000-01-01T00:00:00.000Z)`.
    /// No band data predates the Unix epoch, every instant inside has a four-digit-year ISO 8601 form,
    /// and the difference of any two of them fits easily in `Int64`, so ranges built from imported data
    /// never overflow. Applies to measurement `ts_ms` and session `start_ms`/`end_ms`.
    public static let backupTimeWindow = TimeRange(start: 0, end: 253_402_300_800_000)
    /// Longest motion epoch a backup may contain, in milliseconds (one day).
    public static let maxBackupEpochMillis: Int64 = 86_400_000
    /// Records applied per transaction (and per store-lock acquisition) during import.
    static let importChunkSize = 2_000
    /// Adapter id of import batches for measurements whose backup line names no adapter.
    public static let backupImportAdapterID = "forma-backup"
    /// Distinct (device, adapter, firmware) groups one import creates batches for; further groups fall
    /// back to the device's batch without an adapter, so a hostile file cannot make bookkeeping grow
    /// with every line.
    static let maxImportOrigins = 256
    /// Line bytes parsed into one pending chunk before it is applied, whatever its record count, so
    /// a file of large records (long labels, settings) never piles up in memory.
    static let importChunkByteBudget = 8 * 1_024 * 1_024

    /// Streams the whole store into a backup file (written to `<name>.partial`, synced, then renamed
    /// over the destination atomically).
    ///
    /// Devices, settings, cursors, sessions and corrections are read in one consistent snapshot (one
    /// store-lock acquisition), so every correction's session is in the file even while the user edits
    /// sessions. Measurements are read page by page afterwards, so memory use stays bounded and ingest
    /// can continue while the export runs (records ingested meanwhile may or may not be included).
    /// - Throws: `StoreError.fileError` (also when `url` is this store's own database file),
    ///   `SQLiteError`, or `CancellationError` when the calling task is cancelled.
    @discardableResult
    public func exportBackup(to url: URL) throws -> BackupSummary {
        try refuseDatabaseFileAsDestination(url)
        let exportedAt = timeSource.now()
        var counts: [BackupRecordType: Int] = [:]
        var lineCount = 0
        var oldest: EpochMillis?
        var newest: EpochMillis?
        let byteCount = try AtomicFile.write(to: url) { output in
            func emit(_ type: BackupRecordType, _ line: String) throws {
                try output.write(line)
                counts[type, default: 0] += 1
                lineCount += 1
            }
            func track(_ timestamp: EpochMillis) {
                oldest = min(oldest ?? timestamp, timestamp)
                newest = max(newest ?? timestamp, timestamp)
            }
            try output.write(BackupLine.header(exportedAt: exportedAt))
            lineCount += 1
            let snapshot = try locked { _ in
                BackupSnapshot(devices: try devices(), settings: try allSettings(), cursors: try syncCursors(),
                               sessions: try sessions(includeCandidates: true, includeDeleted: true),
                               corrections: try corrections())
            }
            for device in snapshot.devices {
                try emit(.device, BackupLine.device(device))
            }
            for (key, value) in snapshot.settings.sorted(by: { $0.key < $1.key })
            where !StoreSettingKey.deviceLocal.contains(key) {
                try emit(.setting, BackupLine.setting(key: key, value: value))
            }
            for cursor in snapshot.cursors {
                try emit(.cursor, BackupLine.cursor(cursor))
            }
            for session in snapshot.sessions {
                try emit(.session, BackupLine.session(session))
            }
            for correction in snapshot.corrections {
                try emit(.correction, BackupLine.correction(correction))
            }
            try forEachPage(.heartRate, range: nil, withOrigin: true,
                            decode: BackupOrigin.decoding(.heartRate, RowDecoder.heartRate)) { page in
                for (sample, origin) in page {
                    track(sample.timestamp)
                    try emit(.hr, BackupLine.heartRate(sample, origin: origin))
                }
            }
            try forEachPage(.beatInterval, range: nil, withOrigin: true,
                            decode: BackupOrigin.decoding(.beatInterval, RowDecoder.beatInterval)) { page in
                for (interval, origin) in page {
                    track(interval.timestamp)
                    try emit(.rr, BackupLine.beatInterval(interval, origin: origin))
                }
            }
            try forEachPage(.motion, range: nil, withOrigin: true,
                            decode: BackupOrigin.decoding(.motion, RowDecoder.motion)) { page in
                for (epoch, origin) in page {
                    track(epoch.timestamp)
                    try emit(.motion, BackupLine.motion(epoch, origin: origin))
                }
            }
            try forEachPage(.aux, range: nil, withOrigin: true,
                            decode: BackupOrigin.decoding(.aux, RowDecoder.aux)) { page in
                for (measurement, origin) in page {
                    track(measurement.timestamp)
                    try emit(.aux, BackupLine.aux(measurement, origin: origin))
                }
            }
        }
        var measurementRange: TimeRange?
        if let oldest, let newest {
            let (end, overflow) = newest.addingReportingOverflow(1)
            measurementRange = TimeRange(start: oldest, end: overflow ? newest : end)
        }
        return BackupSummary(fileURL: url, formatVersion: Self.backupFormatVersion, schemaVersion: Self.schemaVersion,
                             exportedAt: exportedAt, counts: counts, lineCount: lineCount, byteCount: byteCount,
                             measurementRange: measurementRange)
    }

    /// Restores a backup into this store, streaming it line by line (lines longer than
    /// `maxBackupLineBytes` are skipped and reported, never loaded).
    ///
    /// - The header must name the `forma-backup` format; a newer `formatVersion` is refused.
    /// - Each line is validated: JSON shape, field types, known codes, finite numbers, the structural
    ///   rules of live ingest and, because a file is untrusted, timeline timestamps inside
    ///   `backupTimeWindow` and motion epochs of at most `maxBackupEpochMillis`. Invalid lines are
    ///   counted and skipped; the reasons for the first 20 are kept in the report.
    /// - Records go through the same dedup keys as sync, so importing the same file twice adds nothing
    ///   (not even provenance rows). Measurements keep their original `source`; their provenance is a
    ///   new `ingest_batch` per device and original adapter and firmware (taken from the line's
    ///   `adapter_id` and `firmware`; `backupImportAdapterID` and no firmware when the line names no
    ///   adapter), with source `.backupImport`, parser version `forma-backup/<format>` and the file name
    ///   as note. A restored band-history record therefore keeps the field-validation key
    ///   (`adapter.firmware`) of the values it holds: a verdict for that adapter and firmware applies to
    ///   it, and no other verdict does.
    /// - Sessions: a backup session is skipped when a session with the same kind, start, end and
    ///   label already exists, except a row created by this same import (two equal sessions in one
    ///   file stay two), and a deleted backup session only matches a deleted row. Of several matches,
    ///   the one with the same deleted state and creation time is used. Otherwise the session is
    ///   inserted with its original origin: `.imported` is not applied because it would turn
    ///   unconfirmed candidates into confirmed sessions. Corrections follow their session.
    /// - Settings are added only when the key is not set on this phone; a different local value is
    ///   kept (counted in `notApplied`). `user_profile` must decode as a `UserProfile`. Keys for which
    ///   `withholdingSettings` returns true (choices only the person using this phone may make) are
    ///   never written — checked inside each chunk's transaction, so an import that stops midway or
    ///   runs again can never apply them (counted in `notApplied` and `settingsWithheld`).
    /// - Sync cursors are NOT applied (they are reported in `cursorsNotApplied`, nothing is stored): a
    ///   cursor written on another phone, or before this store's own last sync, can point past history
    ///   the band has not yet delivered here; applying it would make the next sync skip — and the band
    ///   then discard — records that were never stored.
    ///
    /// Records are applied in transactions of at most `importChunkSize` lines (or about 8 MiB of
    /// lines), taking the store lock per chunk. If the import throws midway (I/O or database error,
    /// cancellation of the calling task), earlier chunks stay applied; running the import again is
    /// safe because of the dedup keys. If `deleteAllData` runs meanwhile, the import stops with
    /// `StoreError.interrupted` rather than restoring the rest of the file into the emptied store.
    /// - Throws: `StoreError.fileError`, `.invalidBackup`, `.unsupportedBackupVersion`, `.interrupted`,
    ///   `SQLiteError`, `CancellationError`.
    public func importBackup(from url: URL,
                             withholdingSettings withhold: (String) -> Bool = { _ in false }) throws -> ImportReport {
        try importBackup(from: url, withholdingSettings: withhold, afterChunk: { _ in })
    }

    /// `importBackup(from:withholdingSettings:)` calling `afterChunk(n)` after the n-th chunk was
    /// committed, outside the store lock (a test seam for what happens between chunks).
    func importBackup(from url: URL, withholdingSettings withhold: (String) -> Bool = { _ in false },
                      afterChunk: (Int) throws -> Void) throws -> ImportReport {
        let reader: BoundedLineReader
        do {
            reader = try BoundedLineReader(url: url, maxLineBytes: Self.maxBackupLineBytes)
        } catch {
            throw StoreError.fileError("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let header = try readBackupHeader(reader)
        let generation = try locked { _ in dataGeneration }
        var state = ImportState(generation: generation, report: ImportReport(
            fileName: url.lastPathComponent, formatVersion: header.formatVersion,
            sourceSchemaVersion: header.schemaVersion, exportedAt: header.exportedAt, batchIDs: [], inserted: [:],
            duplicates: [:], notApplied: [:], settingsWithheld: 0, invalidLines: 0, errors: [], importedRange: nil,
            cursorsNotApplied: []))
        let decoder = JSONDecoder()
        var pending: [(line: Int, record: BackupRecord)] = []
        var pendingBytes = 0
        var chunks = 0
        func flush() throws {
            try applyImportChunk(pending, state: &state, withhold: withhold)
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            chunks += 1
            try afterChunk(chunks)
        }
        var lineNumber = 1
        while let line = try reader.next() {
            lineNumber += 1
            switch line {
            case .tooLong(let byteCount):
                state.reject(line: lineNumber, "line is \(byteCount) bytes, over the \(Self.maxBackupLineBytes)-byte limit")
            case .text(let bytes):
                if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
                do {
                    let envelope = try decoder.decode(BackupEnvelope.self, from: Data(bytes))
                    pending.append((lineNumber, envelope.record))
                    pendingBytes += bytes.count
                } catch {
                    state.reject(line: lineNumber, BackupLineError.describe(error))
                }
            }
            if pending.count >= Self.importChunkSize || pendingBytes >= Self.importChunkByteBudget {
                try flush()
            }
        }
        if !pending.isEmpty {
            try flush()
        }
        return state.finishedReport()
    }

    private func readBackupHeader(_ reader: BoundedLineReader) throws -> BackupHeader {
        guard let first = try reader.next() else { throw StoreError.invalidBackup("the file is empty") }
        guard case .text(var bytes) = first else {
            throw StoreError.invalidBackup("the first line is longer than \(Self.maxBackupLineBytes) bytes")
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let header: BackupHeader
        do {
            header = try JSONDecoder().decode(BackupHeader.self, from: Data(bytes))
        } catch {
            throw StoreError.invalidBackup("the first line is not a Forma backup header")
        }
        guard header.format == Self.backupFormatName else {
            throw StoreError.invalidBackup("format is '\(BackupLineError.excerpt(header.format))', expected '\(Self.backupFormatName)'")
        }
        guard header.formatVersion >= 1 else {
            throw StoreError.invalidBackup("formatVersion \(header.formatVersion) is not valid")
        }
        guard header.formatVersion <= Self.backupFormatVersion else {
            throw StoreError.unsupportedBackupVersion(found: header.formatVersion, supported: Self.backupFormatVersion)
        }
        return header
    }

    /// Applies one chunk of parsed records in a single transaction.
    private func applyImportChunk(_ chunk: [(line: Int, record: BackupRecord)], state: inout ImportState,
                                  withhold: (String) -> Bool) throws {
        try Task.checkCancellation()
        try locked { db in
            guard dataGeneration == state.generation else {
                throw StoreError.interrupted("all data was deleted while the backup was being imported; the import "
                                             + "stopped so the rest of the file is not restored into the emptied store")
            }
            try db.transaction {
                let writer = MeasurementWriter(db: db)
                // A group's import batch (device, original adapter and firmware) is created just before its
                // first record that is actually new, so a batch never exists without records (deleting one
                // later would have to scan every measurement table, whose batch_id columns are not
                // indexed). Until then each record is looked up by its dedup key instead of being inserted.
                func importMeasurement(_ type: BackupRecordType, deviceID: String, origin: BackupOrigin?,
                                       at instant: EpochMillis, exists: () throws -> Bool,
                                       insert: (Int64) throws -> Bool) throws {
                    let key = state.batchKey(deviceID: deviceID, origin: origin)
                    let batchID: Int64
                    if let existing = state.batchIDs[key] {
                        batchID = existing
                    } else if try exists() {
                        state.count(type, stored: false, instant: instant)
                        return
                    } else {
                        batchID = try createImportBatch(for: key, db: db, state: &state)
                    }
                    state.count(type, stored: try insert(batchID), instant: instant)
                }
                for (line, record) in chunk {
                    switch record {
                    case .heartRate(let sample, let origin):
                        try importMeasurement(.hr, deviceID: sample.deviceID, origin: origin, at: sample.timestamp,
                                              exists: { try writer.exists(sample) },
                                              insert: { try writer.insert(sample, batchID: $0) })
                    case .beatInterval(let interval, let origin):
                        try importMeasurement(.rr, deviceID: interval.deviceID, origin: origin, at: interval.timestamp,
                                              exists: { try writer.exists(interval) },
                                              insert: { try writer.insert(interval, batchID: $0) })
                    case .motion(let epoch, let origin):
                        try importMeasurement(.motion, deviceID: epoch.deviceID, origin: origin, at: epoch.timestamp,
                                              exists: { try writer.exists(epoch) },
                                              insert: { try writer.insert(epoch, batchID: $0) })
                    case .aux(let measurement, let origin):
                        try importMeasurement(.aux, deviceID: measurement.deviceID, origin: origin,
                                              at: measurement.timestamp, exists: { try writer.exists(measurement) },
                                              insert: { try writer.insert(measurement, batchID: $0) })
                    case .device(let device):
                        let stored = try db.run(StoreSQL.insertDeviceIfAbsent,
                                                [device.id, device.family.rawValue, device.name, device.firmwareVersion,
                                                 device.hardwareRevision, device.firstSeen, device.lastConnected]) > 0
                        state.count(.device, stored: stored)
                    case .session(let backupID, let session):
                        try importSession(session, backupID: backupID, db: db, state: &state)
                    case .correction(let backupSessionID, let correction):
                        try importCorrection(correction, backupSessionID: backupSessionID, line: line, db: db, state: &state)
                    case .setting(let key, let value):
                        try importSetting(key: key, value: value, db: db, state: &state, withhold: withhold)
                    case .cursor(let cursor):
                        state.noteCursor(cursor)
                    }
                }
            }
        }
    }

    /// The provenance row for this import's measurements of one device and original adapter and
    /// firmware (source `.backupImport`).
    private func createImportBatch(for key: ImportBatchKey, db: SQLiteConnection, state: inout ImportState) throws -> Int64 {
        let provenance = Provenance(deviceID: key.deviceID, adapterID: key.origin?.adapterID ?? Self.backupImportAdapterID,
                                    parserVersion: "\(Self.backupFormatName)/\(state.report.formatVersion)",
                                    firmwareVersion: key.origin?.firmware, source: .backupImport, syncRunID: nil,
                                    createdAt: timeSource.now(), note: state.report.fileName)
        let batchID = try Self.insertProvenance(provenance, db: db)
        state.batchIDs[key] = batchID
        if key.origin != nil { state.originBatches += 1 }
        state.report.batchIDs.append(batchID)
        return batchID
    }

    private func importSession(_ session: Session, backupID: Int64?, db: SQLiteConnection,
                               state: inout ImportState) throws {
        var sql = "SELECT id FROM session WHERE kind = ? AND start_ms = ? AND end_ms = ? AND label IS ?"
        if session.deleted { sql += " AND deleted = 1" }
        sql += " ORDER BY (deleted = ?) DESC, (created_at = ?) DESC, id"
        let candidates = try db.query(sql, [session.kind.rawValue, session.range.start, session.range.end,
                                            session.label, session.deleted, session.createdAt]) { $0.int64(0) }
        if let match = candidates.first(where: { !state.createdSessionIDs.contains($0) }) {
            state.count(.session, stored: false)
            if let backupID { state.sessionIDs[backupID] = match }
        } else {
            let newID = try Self.insertSessionRow(session, db: db)
            state.createdSessionIDs.insert(newID)
            state.count(.session, stored: true, range: session.range)
            if let backupID { state.sessionIDs[backupID] = newID }
        }
    }

    private func importCorrection(_ correction: UserCorrection, backupSessionID: Int64?, line: Int,
                                  db: SQLiteConnection, state: inout ImportState) throws {
        var sessionID: Int64?
        if let backupSessionID {
            guard let mapped = state.sessionIDs[backupSessionID],
                  try db.scalarInt64("SELECT 1 FROM session WHERE id = ?", [mapped]) != nil else {
                state.reject(line: line, "correction refers to session \(backupSessionID), which is not in this backup")
                return
            }
            sessionID = mapped
        }
        let exists = try db.scalarInt64("""
            SELECT 1 FROM user_correction
            WHERE session_id IS ? AND field = ? AND old_value IS ? AND new_value IS ? AND created_at = ? LIMIT 1
            """, [sessionID, correction.field, correction.oldValue, correction.newValue, correction.createdAt]) != nil
        if !exists {
            try db.run(StoreSQL.insertCorrection,
                       [sessionID, correction.field, correction.oldValue, correction.newValue, correction.createdAt])
        }
        state.count(.correction, stored: !exists)
    }

    private func importSetting(key: String, value: String, db: SQLiteConnection, state: inout ImportState,
                               withhold: (String) -> Bool) throws {
        if StoreSettingKey.deviceLocal.contains(key) {
            state.report.notApplied[.setting, default: 0] += 1
        } else if withhold(key) {
            state.report.notApplied[.setting, default: 0] += 1
            state.report.settingsWithheld += 1
        } else if let local = try db.scalarText("SELECT value FROM setting WHERE key = ?", [key]) {
            if local == value {
                state.count(.setting, stored: false)
            } else {
                state.report.notApplied[.setting, default: 0] += 1
            }
        } else {
            try db.run("INSERT INTO setting (key, value) VALUES (?, ?)", [key, value])
            state.count(.setting, stored: true)
        }
    }
}

/// The small, cross-referenced tables of a backup, read under one store-lock acquisition.
private struct BackupSnapshot {
    let devices: [DeviceRecord]
    let settings: [String: String]
    let cursors: [SyncCursor]
    let sessions: [Session]
    let corrections: [UserCorrection]
}

// MARK: - Import bookkeeping

/// One import batch: a device and the adapter and firmware its measurements were decoded with (nil when
/// the backup line names no adapter).
private struct ImportBatchKey: Hashable {
    let deviceID: String
    let origin: BackupOrigin?
}

private struct ImportState {
    /// `FormaStore.dataGeneration` when the import started.
    let generation: UInt64
    var report: ImportReport
    /// Import provenance batch per group (created with the group's first new record).
    var batchIDs: [ImportBatchKey: Int64] = [:]
    /// Batches created for groups with a known adapter (bounded by `FormaStore.maxImportOrigins`).
    var originBatches = 0
    /// Session id in the backup → session id in this store.
    var sessionIDs: [Int64: Int64] = [:]
    /// Session rows inserted by this import (never matched as duplicates of later backup sessions).
    var createdSessionIDs: Set<Int64> = []
    var oldest: EpochMillis?
    var end: EpochMillis?
    /// Position in `report.cursorsNotApplied` per device ID.
    private var cursorPositions: [String: Int] = [:]
    /// The `maxRecordedErrors` lowest-numbered rejections so far, sorted by line. Some problems are only
    /// found when a chunk is applied, after later lines were parsed, so arrival order is not line order.
    private var firstErrors: [(line: Int, reason: String)] = []

    init(generation: UInt64, report: ImportReport) {
        self.generation = generation
        self.report = report
    }

    /// The batch group of a measurement. Past `maxImportOrigins` new groups with a known adapter, records
    /// of further groups go to their device's batch without an adapter (provenance unknown).
    func batchKey(deviceID: String, origin: BackupOrigin?) -> ImportBatchKey {
        let key = ImportBatchKey(deviceID: deviceID, origin: origin)
        guard origin != nil, batchIDs[key] == nil, originBatches >= FormaStore.maxImportOrigins else { return key }
        return ImportBatchKey(deviceID: deviceID, origin: nil)
    }

    mutating func reject(line: Int, _ reason: String) {
        report.invalidLines += 1
        let position = firstErrors.firstIndex { $0.line > line } ?? firstErrors.endIndex
        guard position < ImportReport.maxRecordedErrors else { return }
        firstErrors.insert((line, reason), at: position)
        if firstErrors.count > ImportReport.maxRecordedErrors { firstErrors.removeLast() }
    }

    mutating func count(_ type: BackupRecordType, stored: Bool, instant: EpochMillis) {
        let (end, overflow) = instant.addingReportingOverflow(1)
        count(type, stored: stored, range: TimeRange(start: instant, end: overflow ? instant : end))
    }

    mutating func count(_ type: BackupRecordType, stored: Bool, range: TimeRange? = nil) {
        guard stored else {
            report.duplicates[type, default: 0] += 1
            return
        }
        report.inserted[type, default: 0] += 1
        if let range {
            oldest = min(oldest ?? range.start, range.start)
            end = max(end ?? range.end, range.end)
        }
    }

    /// Counts a cursor line and keeps the newest cursor per device (bounded, see `ImportReport`).
    mutating func noteCursor(_ cursor: SyncCursor) {
        report.notApplied[.cursor, default: 0] += 1
        if let position = cursorPositions[cursor.deviceID] {
            if cursor.updatedAt > report.cursorsNotApplied[position].updatedAt {
                report.cursorsNotApplied[position] = cursor
            }
        } else if report.cursorsNotApplied.count < ImportReport.maxReportedCursors {
            cursorPositions[cursor.deviceID] = report.cursorsNotApplied.count
            report.cursorsNotApplied.append(cursor)
        }
    }

    func finishedReport() -> ImportReport {
        var finished = report
        finished.errors = firstErrors.map { "line \($0.line): \($0.reason)" }
        if let oldest, let end {
            finished.importedRange = TimeRange(start: oldest, end: end)
        }
        return finished
    }
}

// MARK: - Writing lines

/// Builds backup lines. Keys mirror the database columns so the format does not depend on Swift
/// property names.
enum BackupLine {
    static func header(exportedAt: EpochMillis) -> String {
        "{\"format\":\(TextFormat.jsonString(FormaStore.backupFormatName)),\"formatVersion\":\(FormaStore.backupFormatVersion),"
            + "\"schemaVersion\":\(FormaStore.schemaVersion),\"exportedAt\":\(exportedAt),\"app\":\"Forma\"}\n"
    }

    static func device(_ d: DeviceRecord) -> String {
        var o = JSONLineBuilder(.device)
        o.add("id", d.id)
        o.add("family", d.family.rawValue)
        o.add("name", d.name)
        o.add("firmware", d.firmwareVersion)
        o.add("hardware", d.hardwareRevision)
        o.add("first_seen", d.firstSeen)
        o.add("last_connected", d.lastConnected)
        return o.line
    }

    static func heartRate(_ s: HeartRateSample, origin: BackupOrigin?) -> String {
        var o = JSONLineBuilder(.hr)
        o.add("device_id", s.deviceID)
        o.add("ts_ms", s.timestamp)
        o.add("bpm", s.bpm)
        o.add("source", s.source.rawValue)
        o.add("device_time_raw", s.deviceTimeRaw)
        o.add("received_at", s.receivedAt)
        o.add("clock_offset_ms", s.clockOffsetMillis)
        o.add("quality", s.quality.rawValue)
        o.add(origin)
        return o.line
    }

    static func beatInterval(_ b: BeatInterval, origin: BackupOrigin?) -> String {
        var o = JSONLineBuilder(.rr)
        o.add("device_id", b.deviceID)
        o.add("ts_ms", b.timestamp)
        o.add("interval_ms", b.intervalMillis)
        o.add("source", b.source.rawValue)
        o.add("record_key", b.recordKey)
        o.add("idx", b.indexInRecord)
        o.add("received_at", b.receivedAt)
        o.add("timing_basis", b.timingBasis.rawValue)
        o.add("quality", b.quality.rawValue)
        o.add(origin)
        return o.line
    }

    static func motion(_ m: MotionEpoch, origin: BackupOrigin?) -> String {
        var o = JSONLineBuilder(.motion)
        o.add("device_id", m.deviceID)
        o.add("ts_ms", m.timestamp)
        o.add("epoch_ms", m.epochMillis)
        o.add("activity", m.activity)
        o.add("sample_count", m.sampleCount)
        o.add("source", m.source.rawValue)
        o.add("quality", m.quality.rawValue)
        o.add("device_time_raw", m.deviceTimeRaw)
        o.add(origin)
        return o.line
    }

    static func aux(_ a: AuxMeasurement, origin: BackupOrigin?) -> String {
        var o = JSONLineBuilder(.aux)
        o.add("device_id", a.deviceID)
        o.add("ts_ms", a.timestamp)
        o.add("kind", a.kind.rawValue)
        o.add("value", a.value)
        o.add("source", a.source.rawValue)
        o.add("validated", a.validated)
        o.add("quality", a.quality.rawValue)
        o.add(origin)
        return o.line
    }

    static func session(_ s: Session) -> String {
        var o = JSONLineBuilder(.session)
        o.add("id", s.id)
        o.add("kind", s.kind.rawValue)
        o.add("start_ms", s.range.start)
        o.add("end_ms", s.range.end)
        o.add("origin", s.origin.rawValue)
        o.add("label", s.label)
        o.add("device_id", s.deviceID)
        o.add("detector", s.detector)
        o.add("confidence", s.confidence)
        o.add("created_at", s.createdAt)
        o.add("updated_at", s.updatedAt)
        o.add("deleted", s.deleted)
        return o.line
    }

    static func correction(_ c: UserCorrection) -> String {
        var o = JSONLineBuilder(.correction)
        o.add("id", c.id)
        o.add("session_id", c.sessionID)
        o.add("field", c.field)
        o.add("old_value", c.oldValue)
        o.add("new_value", c.newValue)
        o.add("created_at", c.createdAt)
        return o.line
    }

    static func setting(key: String, value: String) -> String {
        var o = JSONLineBuilder(.setting)
        o.add("key", key)
        o.add("value", value)
        return o.line
    }

    static func cursor(_ c: SyncCursor) -> String {
        var o = JSONLineBuilder(.cursor)
        o.add("device_id", c.deviceID)
        o.add("adapter_id", c.adapterID)
        o.add("opaque", c.opaque?.base64EncodedString())
        o.add("newest_record_ms", c.newestPersistedRecordTime)
        o.add("last_complete_ms", c.lastCompleteSyncAt)
        o.add("updated_at", c.updatedAt)
        return o.line
    }
}

/// `{"type":"…","data":{…}}` with fields appended in call order. Nil values are written as `null`.
struct JSONLineBuilder {
    private var text: String
    private var isFirstField = true

    init(_ type: BackupRecordType) {
        text = "{\"type\":\"\(type.rawValue)\",\"data\":{"
    }

    mutating func add(_ key: String, _ value: String?) { field(key, value.map(TextFormat.jsonString) ?? "null") }
    mutating func add(_ key: String, _ value: Int64?) { field(key, value.map { String($0) } ?? "null") }
    mutating func add(_ key: String, _ value: Int) { field(key, String(value)) }
    /// Non-finite numbers have no JSON form and become `null` (the importer then rejects the line).
    mutating func add(_ key: String, _ value: Double?) { field(key, value.flatMap(TextFormat.number) ?? "null") }
    mutating func add(_ key: String, _ value: Bool) { field(key, value ? "true" : "false") }
    /// `adapter_id` and `firmware` of a measurement's batch (both null when unknown).
    mutating func add(_ origin: BackupOrigin?) {
        add("adapter_id", origin?.adapterID)
        add("firmware", origin?.firmware)
    }

    private mutating func field(_ key: String, _ json: String) {
        if !isFirstField { text += "," }
        isFirstField = false
        text += TextFormat.jsonString(key) + ":" + json
    }

    var line: String { text + "}}\n" }
}

// MARK: - Reading lines

struct BackupHeader: Decodable {
    let format: String
    let formatVersion: Int
    let schemaVersion: Int?
    let exportedAt: Int64?
    let app: String?
}

/// The adapter and firmware behind a measurement (its batch's `adapter_id` and `firmware`): what its
/// field-validation key is made of.
struct BackupOrigin: Hashable {
    let adapterID: String
    let firmware: String?

    /// Longest accepted firmware text in a backup line, in UTF-8 bytes.
    static let maxFirmwareBytes = 256

    /// The origin named by a line's `adapter_id` and `firmware`; nil without an adapter (a firmware
    /// alone identifies nothing).
    static func parse(adapterID: String?, firmware: String?) throws -> BackupOrigin? {
        guard let adapterID else { return nil }
        try RecordValidator.identifier(adapterID, "data.adapter_id")
        if let firmware, firmware.utf8.count > maxFirmwareBytes {
            throw BackupLineError("data.firmware is longer than \(maxFirmwareBytes) bytes")
        }
        return BackupOrigin(adapterID: adapterID, firmware: firmware)
    }

    /// Decodes a measurement row followed by its batch's `adapter_id` and `firmware` (the columns
    /// `FormaStore.pageSQL(_:hasRange:withOrigin:)` appends).
    static func decoding<Row>(_ table: MeasurementTable, _ decode: @escaping (SQLiteStatement, Int) -> Row?)
        -> (SQLiteStatement, Int) -> (Row, BackupOrigin?)? {
        let offset = table.columnCount
        return { statement, base in
            guard let row = decode(statement, base) else { return nil }
            let at = base + offset
            let origin = statement.string(at).map { BackupOrigin(adapterID: $0, firmware: statement.string(at + 1)) }
            return (row, origin)
        }
    }
}

/// One parsed, validated backup record.
enum BackupRecord {
    case device(DeviceRecord)
    case heartRate(HeartRateSample, BackupOrigin?)
    case beatInterval(BeatInterval, BackupOrigin?)
    case motion(MotionEpoch, BackupOrigin?)
    case aux(AuxMeasurement, BackupOrigin?)
    /// `backupID` is the session's id in the exporting store (used to attach corrections).
    case session(backupID: Int64?, Session)
    case correction(backupSessionID: Int64?, UserCorrection)
    case setting(key: String, value: String)
    case cursor(SyncCursor)
}

/// A rejected line's reason.
struct BackupLineError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    /// A short, single-line excerpt of untrusted text for error messages.
    static func excerpt(_ text: String, limit: Int = 40) -> String {
        let flattened = String(text.unicodeScalars.map { $0.value < 0x20 ? " " : Character($0) })
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }

    static func describe(_ error: Error) -> String {
        if let lineError = error as? BackupLineError { return lineError.message }
        if let storeError = error as? StoreError {
            switch storeError {
            case .invalidRecord(let detail), .invalidArgument(let detail): return detail
            default: return storeError.description
            }
        }
        guard let decodingError = error as? DecodingError else { return "unreadable record" }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing field '\(path(context.codingPath + [key]))'"
        case .typeMismatch(_, let context):
            return context.codingPath.isEmpty ? "expected a JSON object" : "wrong type for '\(path(context.codingPath))'"
        case .valueNotFound(_, let context):
            return "missing value for '\(path(context.codingPath))'"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not valid JSON" : "invalid value for '\(path(context.codingPath))'"
        @unknown default:
            return "unreadable record"
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }.joined(separator: ".")
    }
}

private func knownCode<Code: RawRepresentable>(_ raw: Code.RawValue, _ field: String) throws -> Code {
    guard let code = Code(rawValue: raw) else {
        throw BackupLineError("unknown \(field) '\(BackupLineError.excerpt(String(describing: raw)))'")
    }
    return code
}

/// `{"type": ..., "data": {...}}`, decoded and validated in one pass.
struct BackupEnvelope: Decodable {
    let record: BackupRecord

    private enum Keys: String, CodingKey {
        case type, data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let typeName = try container.decode(String.self, forKey: .type)
        let type: BackupRecordType = try knownCode(typeName, "record type")
        switch type {
        case .device: record = .device(try container.decode(DeviceData.self, forKey: .data).model())
        case .hr:
            let data = try container.decode(HeartRateData.self, forKey: .data)
            record = .heartRate(try data.model(), try BackupOrigin.parse(adapterID: data.adapterID, firmware: data.firmware))
        case .rr:
            let data = try container.decode(BeatIntervalData.self, forKey: .data)
            record = .beatInterval(try data.model(), try BackupOrigin.parse(adapterID: data.adapterID, firmware: data.firmware))
        case .motion:
            let data = try container.decode(MotionData.self, forKey: .data)
            record = .motion(try data.model(), try BackupOrigin.parse(adapterID: data.adapterID, firmware: data.firmware))
        case .aux:
            let data = try container.decode(AuxData.self, forKey: .data)
            record = .aux(try data.model(), try BackupOrigin.parse(adapterID: data.adapterID, firmware: data.firmware))
        case .session:
            let data = try container.decode(SessionData.self, forKey: .data)
            record = .session(backupID: data.id, try data.model())
        case .correction:
            let data = try container.decode(CorrectionData.self, forKey: .data)
            record = .correction(backupSessionID: data.sessionID, try data.model())
        case .setting:
            let data = try container.decode(SettingData.self, forKey: .data)
            try data.validate()
            record = .setting(key: data.key, value: data.value)
        case .cursor: record = .cursor(try container.decode(CursorData.self, forKey: .data).model())
        }
    }
}

private struct DeviceData: Decodable {
    let id: String
    let family: String
    let name: String
    let firmware: String?
    let hardware: String?
    let firstSeen: Int64
    let lastConnected: Int64?

    enum CodingKeys: String, CodingKey {
        case id, family, name, firmware, hardware
        case firstSeen = "first_seen"
        case lastConnected = "last_connected"
    }

    func model() throws -> DeviceRecord {
        let device = DeviceRecord(id: id, family: try knownCode(family, "device family"), name: name,
                                  firmwareVersion: firmware, hardwareRevision: hardware, firstSeen: firstSeen,
                                  lastConnected: lastConnected)
        try RecordValidator.validate(device)
        return device
    }
}

private struct HeartRateData: Decodable {
    let deviceID: String
    let timestamp: Int64
    let bpm: Int
    let source: Int
    let deviceTimeRaw: Int64?
    let receivedAt: Int64
    let clockOffset: Int64?
    let quality: Int64
    /// Absent in backups written by earlier builds (as is `firmware`).
    let adapterID: String?
    let firmware: String?

    enum CodingKeys: String, CodingKey {
        case bpm, source, quality, firmware
        case deviceID = "device_id"
        case timestamp = "ts_ms"
        case deviceTimeRaw = "device_time_raw"
        case receivedAt = "received_at"
        case clockOffset = "clock_offset_ms"
        case adapterID = "adapter_id"
    }

    func model() throws -> HeartRateSample {
        let sample = HeartRateSample(deviceID: deviceID, timestamp: timestamp, bpm: bpm,
                                     source: try knownCode(source, "source"), deviceTimeRaw: deviceTimeRaw,
                                     receivedAt: receivedAt, clockOffsetMillis: clockOffset,
                                     quality: QualityFlags(rawValue: quality))
        try RecordValidator.validate(sample, at: "data")
        try BackupValidator.instant(timestamp, "data.ts_ms")
        return sample
    }
}

private struct BeatIntervalData: Decodable {
    let deviceID: String
    let timestamp: Int64
    let intervalMillis: Double
    let source: Int
    let recordKey: Int64
    let index: Int
    let receivedAt: Int64
    let timingBasis: Int
    let quality: Int64
    let adapterID: String?
    let firmware: String?

    enum CodingKeys: String, CodingKey {
        case source, quality, firmware
        case adapterID = "adapter_id"
        case deviceID = "device_id"
        case timestamp = "ts_ms"
        case intervalMillis = "interval_ms"
        case recordKey = "record_key"
        case index = "idx"
        case receivedAt = "received_at"
        case timingBasis = "timing_basis"
    }

    func model() throws -> BeatInterval {
        let interval = BeatInterval(deviceID: deviceID, timestamp: timestamp, intervalMillis: intervalMillis,
                                    source: try knownCode(source, "source"), recordKey: recordKey,
                                    indexInRecord: index, receivedAt: receivedAt,
                                    timingBasis: try knownCode(timingBasis, "timing_basis"),
                                    quality: QualityFlags(rawValue: quality))
        try RecordValidator.validate(interval, at: "data")
        try BackupValidator.instant(timestamp, "data.ts_ms")
        return interval
    }
}

private struct MotionData: Decodable {
    let deviceID: String
    let timestamp: Int64
    let epochMillis: Int64
    let activity: Double
    let sampleCount: Int
    let source: Int
    let quality: Int64
    /// Absent in backups written before schema v2.
    let deviceTimeRaw: Int64?
    let adapterID: String?
    let firmware: String?

    enum CodingKeys: String, CodingKey {
        case activity, source, quality, firmware
        case adapterID = "adapter_id"
        case deviceID = "device_id"
        case timestamp = "ts_ms"
        case epochMillis = "epoch_ms"
        case sampleCount = "sample_count"
        case deviceTimeRaw = "device_time_raw"
    }

    func model() throws -> MotionEpoch {
        let epoch = MotionEpoch(deviceID: deviceID, timestamp: timestamp, epochMillis: epochMillis, activity: activity,
                                sampleCount: sampleCount, source: try knownCode(source, "source"),
                                quality: QualityFlags(rawValue: quality), deviceTimeRaw: deviceTimeRaw)
        try RecordValidator.validate(epoch, at: "data")
        try BackupValidator.instant(timestamp, "data.ts_ms")
        try BackupValidator.epochLength(epochMillis)
        return epoch
    }
}

private struct AuxData: Decodable {
    let deviceID: String
    let timestamp: Int64
    let kind: String
    let value: Double
    let source: Int
    let validated: Bool
    let quality: Int64
    let adapterID: String?
    let firmware: String?

    enum CodingKeys: String, CodingKey {
        case kind, value, source, validated, quality, firmware
        case adapterID = "adapter_id"
        case deviceID = "device_id"
        case timestamp = "ts_ms"
    }

    func model() throws -> AuxMeasurement {
        let measurement = AuxMeasurement(deviceID: deviceID, timestamp: timestamp, kind: try knownCode(kind, "aux kind"),
                                         value: value, source: try knownCode(source, "source"), validated: validated,
                                         quality: QualityFlags(rawValue: quality))
        try RecordValidator.validate(measurement, at: "data")
        try BackupValidator.instant(timestamp, "data.ts_ms")
        return measurement
    }
}

private struct SessionData: Decodable {
    let id: Int64?
    let kind: String
    let start: Int64
    let end: Int64
    let origin: String
    let label: String?
    let deviceID: String?
    let detector: String?
    let confidence: Double?
    let createdAt: Int64
    let updatedAt: Int64
    let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, origin, label, detector, confidence, deleted
        case start = "start_ms"
        case end = "end_ms"
        case deviceID = "device_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func model() throws -> Session {
        guard end >= start else { throw BackupLineError("session end_ms is before start_ms") }
        try BackupValidator.sessionBounds(start: start, end: end)
        let session = Session(kind: try knownCode(kind, "session kind"), range: TimeRange(start: start, end: end),
                              origin: try knownCode(origin, "session origin"), label: label, deviceID: deviceID,
                              detector: detector, confidence: confidence, createdAt: createdAt, updatedAt: updatedAt,
                              deleted: deleted)
        try RecordValidator.validate(session)
        return session
    }
}

private struct CorrectionData: Decodable {
    let id: Int64?
    let sessionID: Int64?
    let field: String
    let oldValue: String?
    let newValue: String?
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, field
        case sessionID = "session_id"
        case oldValue = "old_value"
        case newValue = "new_value"
        case createdAt = "created_at"
    }

    func model() throws -> UserCorrection {
        guard !field.isEmpty else { throw BackupLineError("correction field is empty") }
        return UserCorrection(sessionID: sessionID, field: field, oldValue: oldValue, newValue: newValue,
                              createdAt: createdAt)
    }
}

private struct SettingData: Decodable {
    let key: String
    let value: String

    /// Key rules of `setSetting`; well-known keys must also hold what their readers expect, so a
    /// restored `user_profile` can never make `userProfile()` fail.
    func validate() throws {
        try FormaStore.validateSettingKey(key)
        if key == StoreSettingKey.userProfile {
            do {
                _ = try JSONDecoder().decode(UserProfile.self, from: Data(value.utf8))
            } catch {
                throw BackupLineError("setting user_profile is not a valid user profile")
            }
        }
    }
}

private struct CursorData: Decodable {
    let deviceID: String
    let adapterID: String
    let opaque: String?
    let newestRecord: Int64?
    let lastComplete: Int64?
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case opaque
        case deviceID = "device_id"
        case adapterID = "adapter_id"
        case newestRecord = "newest_record_ms"
        case lastComplete = "last_complete_ms"
        case updatedAt = "updated_at"
    }

    func model() throws -> SyncCursor {
        var bytes: Data?
        if let opaque {
            guard let decoded = Data(base64Encoded: opaque) else { throw BackupLineError("cursor opaque is not base64") }
            bytes = decoded
        }
        let cursor = SyncCursor(deviceID: deviceID, adapterID: adapterID, opaque: bytes,
                                newestPersistedRecordTime: newestRecord, lastCompleteSyncAt: lastComplete,
                                updatedAt: updatedAt)
        try RecordValidator.validate(cursor, at: "data")
        return cursor
    }
}
