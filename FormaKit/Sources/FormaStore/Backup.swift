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

    /// Name of the imported file (also stored as the note of the import's `ingest_batch` rows).
    public var fileName: String
    /// Backup format version read from the header.
    public var formatVersion: Int
    /// Schema version of the store that wrote the backup (informational).
    public var sourceSchemaVersion: Int?
    /// Export time from the header, epoch milliseconds (UTC), if present.
    public var exportedAt: EpochMillis?
    /// `ingest_batch` rows created for imported measurements (one per device, source `.backupImport`,
    /// note = file name).
    public var batchIDs: [Int64]
    /// Records newly stored, per type.
    public var inserted: [BackupRecordType: Int]
    /// Valid records that were already present (same dedup key), per type.
    public var duplicates: [BackupRecordType: Int]
    /// Valid records deliberately not applied, per type: sync cursors (see `importBackup`) and settings
    /// that only describe the exporting phone.
    public var notApplied: [BackupRecordType: Int]
    /// Lines skipped because they could not be read or failed validation.
    public var invalidLines: Int
    /// Reasons for the `maxRecordedErrors` lowest-numbered invalid lines, as "line N: reason", in line order.
    public var errors: [String]
    /// Smallest range covering every newly stored measurement and session (`[oldest, newest + 1 ms)`);
    /// derived values inside it should be recomputed. Nil when nothing new was stored.
    public var importedRange: TimeRange?
    /// Sync cursors found in the backup. Informational only; never applied to sync state.
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
/// `null`; blobs as base64). Derived metrics, provenance batches, raw frames, connection history
/// and sync runs are not included: they are recomputable or device-local diagnostics.
extension FormaStore {
    /// Value of the header's `format` field.
    public static let backupFormatName = "forma-backup"
    /// Newest backup format this build writes and reads.
    public static let backupFormatVersion = 1
    /// Longest accepted backup line (1 MiB). Longer lines are skipped and reported, never loaded.
    public static let maxBackupLineBytes = 1_048_576
    /// Records applied per transaction (and per store-lock acquisition) during import.
    static let importChunkSize = 2_000

    /// Streams the whole store into a backup file (written to `<name>.partial`, synced, then moved
    /// into place). Measurements are read page by page, so memory use stays bounded and ingest can
    /// continue while the export runs.
    @discardableResult
    public func exportBackup(to url: URL) throws -> BackupSummary {
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
            for device in try devices() {
                try emit(.device, BackupLine.device(device))
            }
            for (key, value) in try allSettings().sorted(by: { $0.key < $1.key })
            where !StoreSettingKey.deviceLocal.contains(key) {
                try emit(.setting, BackupLine.setting(key: key, value: value))
            }
            for cursor in try syncCursors() {
                try emit(.cursor, BackupLine.cursor(cursor))
            }
            for session in try sessions(includeCandidates: true, includeDeleted: true) {
                try emit(.session, BackupLine.session(session))
            }
            for correction in try corrections() {
                try emit(.correction, BackupLine.correction(correction))
            }
            try forEachPage(.heartRate, range: nil, decode: RowDecoder.heartRate) { page in
                for sample in page {
                    track(sample.timestamp)
                    try emit(.hr, BackupLine.heartRate(sample))
                }
            }
            try forEachPage(.beatInterval, range: nil, decode: RowDecoder.beatInterval) { page in
                for interval in page {
                    track(interval.timestamp)
                    try emit(.rr, BackupLine.beatInterval(interval))
                }
            }
            try forEachPage(.motion, range: nil, decode: RowDecoder.motion) { page in
                for epoch in page {
                    track(epoch.timestamp)
                    try emit(.motion, BackupLine.motion(epoch))
                }
            }
            try forEachPage(.aux, range: nil, decode: RowDecoder.aux) { page in
                for measurement in page {
                    track(measurement.timestamp)
                    try emit(.aux, BackupLine.aux(measurement))
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
    /// - Each line is validated (JSON shape, field types, known codes, finite numbers, the same
    ///   structural rules as live ingest). Invalid lines are counted and skipped; the first 20 reasons
    ///   are kept in the report.
    /// - Records go through the same dedup keys as sync, so importing the same file twice adds nothing.
    ///   Measurements keep their original `source`; their provenance is a new `ingest_batch` per device
    ///   with source `.backupImport` and the file name as note.
    /// - Sessions become new rows unless an identical (kind, start, end, label) session exists;
    ///   corrections are attached to the imported (or matching) session; settings are added only when
    ///   the key is not set on this phone.
    /// - Sync cursors are NOT applied (they are returned in `cursorsNotApplied`): a cursor written on
    ///   another phone, or before this store's own last sync, can point past history the band has not
    ///   yet delivered here; applying it would make the next sync skip — and the band then discard —
    ///   records that were never stored.
    ///
    /// Records are applied in transactions of `importChunkSize` lines, taking the store lock per chunk.
    /// If the import throws midway (I/O or database error), earlier chunks stay applied; running the
    /// import again is safe because of the dedup keys.
    /// - Throws: `StoreError.fileError`, `.invalidBackup`, `.unsupportedBackupVersion`, `SQLiteError`.
    public func importBackup(from url: URL) throws -> ImportReport {
        let reader: BoundedLineReader
        do {
            reader = try BoundedLineReader(url: url, maxLineBytes: Self.maxBackupLineBytes)
        } catch {
            throw StoreError.fileError("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let header = try readBackupHeader(reader)
        var state = ImportState(report: ImportReport(
            fileName: url.lastPathComponent, formatVersion: header.formatVersion,
            sourceSchemaVersion: header.schemaVersion, exportedAt: header.exportedAt, batchIDs: [], inserted: [:],
            duplicates: [:], notApplied: [:], invalidLines: 0, errors: [], importedRange: nil, cursorsNotApplied: []))
        let decoder = JSONDecoder()
        var pending: [(line: Int, record: BackupRecord)] = []
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
                } catch {
                    state.reject(line: lineNumber, BackupLineError.describe(error))
                }
            }
            if pending.count >= Self.importChunkSize {
                try applyImportChunk(pending, state: &state)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try applyImportChunk(pending, state: &state)
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
    private func applyImportChunk(_ chunk: [(line: Int, record: BackupRecord)], state: inout ImportState) throws {
        try locked { db in
            try db.transaction {
                // Batches made by earlier chunks are gone if the store was wiped in between.
                for (deviceID, batchID) in state.batchIDs {
                    if try db.scalarInt64("SELECT 1 FROM ingest_batch WHERE id = ?", [batchID]) == nil {
                        state.batchIDs[deviceID] = nil
                        state.report.batchIDs.removeAll { $0 == batchID }
                    }
                }
                let writer = MeasurementWriter(db: db)
                for (line, record) in chunk {
                    switch record {
                    case .heartRate(let sample):
                        let batchID = try importBatchID(for: sample.deviceID, db: db, state: &state)
                        state.count(.hr, stored: try writer.insert(sample, batchID: batchID), instant: sample.timestamp)
                    case .beatInterval(let interval):
                        let batchID = try importBatchID(for: interval.deviceID, db: db, state: &state)
                        state.count(.rr, stored: try writer.insert(interval, batchID: batchID), instant: interval.timestamp)
                    case .motion(let epoch):
                        let batchID = try importBatchID(for: epoch.deviceID, db: db, state: &state)
                        state.count(.motion, stored: try writer.insert(epoch, batchID: batchID), instant: epoch.timestamp)
                    case .aux(let measurement):
                        let batchID = try importBatchID(for: measurement.deviceID, db: db, state: &state)
                        state.count(.aux, stored: try writer.insert(measurement, batchID: batchID),
                                    instant: measurement.timestamp)
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
                        if StoreSettingKey.deviceLocal.contains(key) {
                            state.report.notApplied[.setting, default: 0] += 1
                        } else {
                            let stored = try db.run("INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO NOTHING",
                                                    [key, value]) > 0
                            state.count(.setting, stored: stored)
                        }
                    case .cursor(let cursor):
                        state.report.notApplied[.cursor, default: 0] += 1
                        state.report.cursorsNotApplied.append(cursor)
                    }
                }
            }
        }
    }

    private func importBatchID(for deviceID: String, db: SQLiteConnection, state: inout ImportState) throws -> Int64 {
        if let existing = state.batchIDs[deviceID] { return existing }
        let provenance = Provenance(deviceID: deviceID, adapterID: "forma-backup",
                                    parserVersion: "\(Self.backupFormatName)/\(state.report.formatVersion)",
                                    firmwareVersion: nil, source: .backupImport, syncRunID: nil,
                                    createdAt: timeSource.now(), note: state.report.fileName)
        let batchID = try Self.insertProvenance(provenance, db: db)
        state.batchIDs[deviceID] = batchID
        state.report.batchIDs.append(batchID)
        return batchID
    }

    private func importSession(_ session: Session, backupID: Int64?, db: SQLiteConnection,
                               state: inout ImportState) throws {
        let existing = try db.scalarInt64("""
            SELECT id FROM session WHERE kind = ? AND start_ms = ? AND end_ms = ? AND label IS ? ORDER BY id LIMIT 1
            """, [session.kind.rawValue, session.range.start, session.range.end, session.label])
        if let existing {
            state.count(.session, stored: false)
            if let backupID { state.sessionIDs[backupID] = existing }
        } else {
            let newID = try Self.insertSessionRow(session, db: db)
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
}

// MARK: - Import bookkeeping

private struct ImportState {
    var report: ImportReport
    /// Import provenance batch per device ID.
    var batchIDs: [String: Int64] = [:]
    /// Session id in the backup → session id in this store.
    var sessionIDs: [Int64: Int64] = [:]
    var oldest: EpochMillis?
    var end: EpochMillis?
    /// The `maxRecordedErrors` lowest-numbered rejections so far, sorted by line. Some problems are only
    /// found when a chunk is applied, after later lines were parsed, so arrival order is not line order.
    private var firstErrors: [(line: Int, reason: String)] = []

    init(report: ImportReport) {
        self.report = report
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

    static func heartRate(_ s: HeartRateSample) -> String {
        var o = JSONLineBuilder(.hr)
        o.add("device_id", s.deviceID)
        o.add("ts_ms", s.timestamp)
        o.add("bpm", s.bpm)
        o.add("source", s.source.rawValue)
        o.add("device_time_raw", s.deviceTimeRaw)
        o.add("received_at", s.receivedAt)
        o.add("clock_offset_ms", s.clockOffsetMillis)
        o.add("quality", s.quality.rawValue)
        return o.line
    }

    static func beatInterval(_ b: BeatInterval) -> String {
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
        return o.line
    }

    static func motion(_ m: MotionEpoch) -> String {
        var o = JSONLineBuilder(.motion)
        o.add("device_id", m.deviceID)
        o.add("ts_ms", m.timestamp)
        o.add("epoch_ms", m.epochMillis)
        o.add("activity", m.activity)
        o.add("sample_count", m.sampleCount)
        o.add("source", m.source.rawValue)
        o.add("quality", m.quality.rawValue)
        return o.line
    }

    static func aux(_ a: AuxMeasurement) -> String {
        var o = JSONLineBuilder(.aux)
        o.add("device_id", a.deviceID)
        o.add("ts_ms", a.timestamp)
        o.add("kind", a.kind.rawValue)
        o.add("value", a.value)
        o.add("source", a.source.rawValue)
        o.add("validated", a.validated)
        o.add("quality", a.quality.rawValue)
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

/// One parsed, validated backup record.
enum BackupRecord {
    case device(DeviceRecord)
    case heartRate(HeartRateSample)
    case beatInterval(BeatInterval)
    case motion(MotionEpoch)
    case aux(AuxMeasurement)
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
        case .hr: record = .heartRate(try container.decode(HeartRateData.self, forKey: .data).model())
        case .rr: record = .beatInterval(try container.decode(BeatIntervalData.self, forKey: .data).model())
        case .motion: record = .motion(try container.decode(MotionData.self, forKey: .data).model())
        case .aux: record = .aux(try container.decode(AuxData.self, forKey: .data).model())
        case .session:
            let data = try container.decode(SessionData.self, forKey: .data)
            record = .session(backupID: data.id, try data.model())
        case .correction:
            let data = try container.decode(CorrectionData.self, forKey: .data)
            record = .correction(backupSessionID: data.sessionID, try data.model())
        case .setting:
            let data = try container.decode(SettingData.self, forKey: .data)
            try FormaStore.validateSettingKey(data.key)
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

    enum CodingKeys: String, CodingKey {
        case bpm, source, quality
        case deviceID = "device_id"
        case timestamp = "ts_ms"
        case deviceTimeRaw = "device_time_raw"
        case receivedAt = "received_at"
        case clockOffset = "clock_offset_ms"
    }

    func model() throws -> HeartRateSample {
        let sample = HeartRateSample(deviceID: deviceID, timestamp: timestamp, bpm: bpm,
                                     source: try knownCode(source, "source"), deviceTimeRaw: deviceTimeRaw,
                                     receivedAt: receivedAt, clockOffsetMillis: clockOffset,
                                     quality: QualityFlags(rawValue: quality))
        try RecordValidator.validate(sample, at: "data")
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

    enum CodingKeys: String, CodingKey {
        case source, quality
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

    enum CodingKeys: String, CodingKey {
        case activity, source, quality
        case deviceID = "device_id"
        case timestamp = "ts_ms"
        case epochMillis = "epoch_ms"
        case sampleCount = "sample_count"
    }

    func model() throws -> MotionEpoch {
        let epoch = MotionEpoch(deviceID: deviceID, timestamp: timestamp, epochMillis: epochMillis, activity: activity,
                                sampleCount: sampleCount, source: try knownCode(source, "source"),
                                quality: QualityFlags(rawValue: quality))
        try RecordValidator.validate(epoch, at: "data")
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

    enum CodingKeys: String, CodingKey {
        case kind, value, source, validated, quality
        case deviceID = "device_id"
        case timestamp = "ts_ms"
    }

    func model() throws -> AuxMeasurement {
        let measurement = AuxMeasurement(deviceID: deviceID, timestamp: timestamp, kind: try knownCode(kind, "aux kind"),
                                         value: value, source: try knownCode(source, "source"), validated: validated,
                                         quality: QualityFlags(rawValue: quality))
        try RecordValidator.validate(measurement, at: "data")
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
