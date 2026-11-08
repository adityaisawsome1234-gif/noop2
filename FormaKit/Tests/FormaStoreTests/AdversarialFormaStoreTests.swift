// Adversarial tests for FormaStore, written from the module spec (not from the implementation):
// boundary values, hostile/malformed input, property-style invariants against reference models,
// round trips, DST edges and large inputs.
//
// Tests whose failure demonstrated an IMPLEMENTATION bug are tagged `IMPLEMENTATION BUG` in a
// comment directly above them. All three bugs (raw-frame byte bound after a shrinking reopen,
// destroyDatabaseFiles on a directory, exporting onto the live database) have been fixed in the
// implementation, so these tests now pass unchanged.

import Foundation
import Testing
import FormaCore
@testable import FormaStore

// MARK: - Helpers (prefixed `adv` / `Adv` to stay clear of the shared test support)

private let advHour = EpochMillis.millisPerHour

private struct AdvBoom: Error, Equatable {}

/// Thread-safe value box for multi-threaded tests.
private final class AdvLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's days_from_civil), used to
/// check exported ISO 8601 strings independently of the implementation's formatter.
private func advDaysFromCivil(_ year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

/// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|+00:00)` into epoch milliseconds; nil for anything else
/// (including local-time strings without a UTC designator).
private func advParseISO8601UTCMillis(_ text: String) -> Int64? {
    let chars = Array(text.utf8)
    func number(_ range: Range<Int>) -> Int64? {
        guard range.upperBound <= chars.count, !range.isEmpty else { return nil }
        var value: Int64 = 0
        for index in range {
            let c = chars[index]
            guard c >= 0x30, c <= 0x39 else { return nil }
            value = value * 10 + Int64(c - 0x30)
        }
        return value
    }
    guard chars.count >= 20, chars[4] == 0x2D, chars[7] == 0x2D, chars[10] == 0x54, chars[13] == 0x3A,
          chars[16] == 0x3A,
          let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
          let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
          (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
    var index = 19
    var millis: Int64 = 0
    if index < chars.count, chars[index] == 0x2E {
        index += 1
        var digits = 0
        var fraction: Int64 = 0
        while index < chars.count, chars[index] >= 0x30, chars[index] <= 0x39 {
            if digits < 3 { fraction = fraction * 10 + Int64(chars[index] - 0x30) }
            digits += 1
            index += 1
        }
        guard digits > 0 else { return nil }
        if digits < 3 {
            for _ in digits..<3 { fraction *= 10 }
        }
        millis = fraction
    }
    let suffix = String(decoding: chars[index...], as: UTF8.self)
    guard suffix == "Z" || suffix == "+00:00" else { return nil }
    let days = advDaysFromCivil(year, month, day)
    return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1_000 + millis
}

private func advWriteLines(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws {
    var text = lines.joined(separator: "\n")
    if trailingNewline { text += "\n" }
    try Data(text.utf8).write(to: url)
}

private let advHeaderLine = #"{"format":"forma-backup","formatVersion":1,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#

private func advHRLine(_ ts: EpochMillis, device: String = "band-A", bpm: Int = 60, source: Int = 2) -> String {
    #"{"type":"hr","data":{"device_id":"\#(device)","ts_ms":\#(ts),"bpm":\#(bpm),"source":\#(source),"#
        + #""device_time_raw":null,"received_at":\#(ts),"clock_offset_ms":null,"quality":0}}"#
}

private func advFileBytes(_ path: String) -> Data {
    (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
}

private func advContains(_ haystack: Data, _ needle: String) -> Bool {
    haystack.range(of: Data(needle.utf8)) != nil
}

/// Every table named in the spec's schema v1.
private let advSpecTables: Set<String> = [
    "device", "ingest_batch", "hr_sample", "beat_interval", "motion_epoch", "aux_measurement", "raw_frame",
    "connection_event", "sync_cursor", "sync_run", "session", "user_correction", "derived_metric", "setting",
]

// MARK: - SQLite wrapper

@Suite("Adversarial: SQLite wrapper")
struct AdversarialSQLiteTests {
    @Test func integerAndRealExtremesRoundTripExactly() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try db.execute("CREATE TABLE t (i INTEGER, r REAL)")
        let integers: [Int64] = [.min, .min + 1, -1, 0, 1, .max - 1, .max]
        let reals: [Double] = [.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude,
                               .leastNormalMagnitude, 0.1 + 0.2, 1e-300, -123_456.789]
        let insert = try db.prepare("INSERT INTO t (i, r) VALUES (?, ?)")
        for (integer, real) in zip(integers, reals) {
            insert.reset()
            try insert.bind(integer, at: 1)
            try insert.bind(real, at: 2)
            #expect(try insert.step() == .done)
        }
        let rows = try db.query("SELECT i, r FROM t ORDER BY rowid") { s in (s.int64(0), s.double(1)) }
        #expect(rows.map(\.0) == integers.map { Optional($0) })
        #expect(rows.map { $0.1?.bitPattern } == reals.map { Optional($0.bitPattern) })
    }

    @Test func textWithEmbeddedNULAndAstralScalarsIsStoredByteExact() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try db.execute("CREATE TABLE t (s TEXT UNIQUE)")
        let values = ["x\u{0}1", "x\u{0}2", "\u{0}", "\u{1F9EA}\u{200D}e\u{301}", "\u{FEFF}bom", String(repeating: "\u{10FFFF}", count: 3)]
        for value in values {
            #expect(try db.run("INSERT INTO t (s) VALUES (?)", [value]) == 1)
        }
        // Distinct values that only differ after a NUL must not collide in a UNIQUE index.
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM t") == Int64(values.count))
        let back = try db.query("SELECT s FROM t ORDER BY rowid") { $0.string(0) }
        #expect(back.map { Array($0.utf8) } == values.map { Array($0.utf8) })
        #expect(try db.scalarInt64("SELECT length(CAST(s AS BLOB)) FROM t WHERE s = ?", ["x\u{0}2"]) == 3)
    }

    @Test func boundTextAndBlobsAreCopiedBeforeTheirSwiftStorageIsReleased() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try db.execute("CREATE TABLE t (i INTEGER, s TEXT, b BLOB)")
        func text(_ i: Int) -> String { String(repeating: "\u{1F600}q", count: 40 + i % 11) + "#\(i)" }
        func blob(_ i: Int) -> Data { Data((0..<(100 + i % 17)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) }) }
        let insert = try db.prepare("INSERT INTO t (i, s, b) VALUES (?, ?, ?)")
        for i in 0..<300 {
            insert.reset()
            // The bound values are temporaries: nothing keeps their storage alive after bind.
            try insert.bind(Int64(i), at: 1)
            try insert.bind(text(i), at: 2)
            try insert.bind(blob(i), at: 3)
            // Churn the allocator so freed buffers are likely to be reused before step().
            var churn: [String] = []
            for j in 0..<20 { churn.append(String(repeating: "z", count: 150 + j)) }
            #expect(churn.count == 20)
            try insert.step()
        }
        let rows = try db.query("SELECT i, s, b FROM t ORDER BY i") { s in (s.int(0), s.string(1), s.data(2)) }
        #expect(rows.count == 300)
        for row in rows {
            let i = try #require(row.0)
            #expect(row.1 == text(i))
            #expect(row.2 == blob(i))
        }
    }

    @Test func everyGetterReturnsNilForSQLNullInsteadOfZero() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        let statement = try db.prepare("SELECT NULL")
        #expect(try statement.step() == .row)
        #expect(statement.isNull(0))
        #expect(statement.int64(0) == nil)
        #expect(statement.int(0) == nil)
        #expect(statement.double(0) == nil)
        #expect(statement.string(0) == nil)
        #expect(statement.data(0) == nil)
        #expect(statement.bytes(0) == nil)
        #expect(statement.bool(0) == nil)
        #expect(statement.value(0) == .null)
        // Reading past the last column is nil too, never a crash.
        #expect(statement.int64(1) == nil && statement.string(-1) == nil)
    }

    @Test func nilBindsNullForEveryTypedOverload() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        let statement = try db.prepare("SELECT ?1 IS NULL, ?2 IS NULL, ?3 IS NULL, ?4 IS NULL, ?5 IS NULL, ?6 IS NULL")
        try statement.bind(Int64?.none, at: 1)
        try statement.bind(Int?.none, at: 2)
        try statement.bind(Double?.none, at: 3)
        try statement.bind(String?.none, at: 4)
        try statement.bind(Data?.none, at: 5)
        try statement.bind([UInt8]?.none, at: 6)
        #expect(try statement.step() == .row)
        #expect((0..<6).map { statement.int64($0) } == Array(repeating: Int64(1), count: 6))
    }

    @Test func preparingTextWithoutAStatementThrowsInsteadOfCrashing() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        for sql in ["", "   ", "-- just a comment\n", ";"] {
            #expect(throws: SQLiteError.self) { _ = try db.prepare(sql) }
        }
        #expect(throws: SQLiteError.self) { try db.prepare("SELECT ?").bind(Int64(1), at: 2) }
        #expect(throws: SQLiteError.self) { try db.prepare("SELECT ?").bind(Int64(1), at: 0) }
    }

    @Test func errorsCarryPrimaryCodeMessageAndSQL() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        let syntax = #expect(throws: SQLiteError.self) { _ = try db.prepare("SELEC 1") }
        #expect(syntax?.code == 1)
        #expect(syntax?.sql == "SELEC 1")
        #expect(syntax?.message.isEmpty == false)
        try db.execute("CREATE TABLE u (k INTEGER PRIMARY KEY)")
        try db.run("INSERT INTO u (k) VALUES (?)", [7])
        let constraint = #expect(throws: SQLiteError.self) { try db.run("INSERT INTO u (k) VALUES (?)", [7]) }
        #expect(constraint?.code == 19)
        #expect(constraint?.sql == "INSERT INTO u (k) VALUES (?)")
    }

    @Test func transactionRethrowsTheOriginalErrorAndRollsBack() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try db.execute("CREATE TABLE t (x INTEGER)")
        #expect(throws: AdvBoom()) {
            try db.transaction {
                for x in 0..<100 { try db.run("INSERT INTO t (x) VALUES (?)", [x]) }
                throw AdvBoom()
            }
        }
        #expect(!db.isInTransaction)
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM t") == 0)
        let value = try db.transaction { () -> Int in
            try db.run("INSERT INTO t (x) VALUES (1)")
            return 42
        }
        #expect(value == 42)
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM t") == 1)
    }

    @Test func changesAndLastInsertRowIDReflectTheLastStatement() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, x INTEGER UNIQUE)")
        for x in 1...5 { try db.run("INSERT INTO t (x) VALUES (?)", [x]) }
        #expect(try db.run("UPDATE t SET x = x + 10 WHERE x >= 3") == 3)
        #expect(db.changes == 3)
        #expect(try db.run("INSERT OR IGNORE INTO t (x) VALUES (13)") == 0)
        try db.run("INSERT INTO t (id, x) VALUES (4242, 99)")
        #expect(db.lastInsertRowID == 4242)
        #expect(try db.run("DELETE FROM t") == 6)
    }

    @Test func emptyTextAndEmptyBlobAreNotNull() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        let statement = try db.prepare("SELECT ?, ?, typeof(?1), typeof(?2)")
        try statement.bind("", at: 1)
        try statement.bind([UInt8](), at: 2)
        #expect(try statement.step() == .row)
        #expect(statement.string(0) == "")
        #expect(statement.data(1) == Data())
        #expect(statement.string(2) == "text")
        #expect(statement.string(3) == "blob")
    }

    @Test func largeBlobRoundTrips() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        var generator = SplitMix64(seed: 77)
        let blob = Data((0..<(3 * 1_024 * 1_024)).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        try db.execute("CREATE TABLE t (b BLOB)")
        try db.run("INSERT INTO t (b) VALUES (?)", [blob])
        #expect(try db.query("SELECT b FROM t") { $0.data(0) }.first == blob)
    }
}

// MARK: - Schema v1 conformance

private struct AdvColumn {
    let name: String
    let type: String
    let notNull: Bool
    let defaultValue: String?
    let primaryKeyPosition: Int
}

private func advColumns(_ db: SQLiteConnection, _ table: String) throws -> [AdvColumn] {
    try db.query("PRAGMA table_info(\(table))") { s in
        guard let name = s.string(1) else { return nil }
        return AdvColumn(name: name, type: (s.string(2) ?? "").uppercased(), notNull: s.int(3) == 1,
                         defaultValue: s.string(4), primaryKeyPosition: s.int(5) ?? 0)
    }
}

/// (unique, ordered column names) for every index of `table`, including automatic ones.
private func advIndexes(_ db: SQLiteConnection, _ table: String) throws -> [(unique: Bool, columns: [String])] {
    let list = try db.query("PRAGMA index_list(\(table))") { s -> (String, Bool)? in
        guard let name = s.string(1) else { return nil }
        return (name, s.int(2) == 1)
    }
    return try list.map { name, unique in
        let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let columns = try db.query("PRAGMA index_info(\(quoted))") { s -> (Int, String)? in
            guard let seq = s.int(0), let column = s.string(2) else { return nil }
            return (seq, column)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return (unique, columns)
    }
}

@Suite("Adversarial: schema matches the spec (v1 tables plus v2 raw-identity keys)")
struct AdversarialSchemaTests {
    static let specColumns: [String: [String]] = [
        "device": ["id", "family", "name", "firmware", "hardware", "first_seen", "last_connected"],
        "ingest_batch": ["id", "device_id", "adapter_id", "parser_version", "firmware", "source", "sync_run_id",
                         "created_at", "note"],
        "hr_sample": ["device_id", "ts_ms", "bpm", "source", "device_time_raw", "received_at", "clock_offset_ms",
                      "quality", "batch_id"],
        "beat_interval": ["device_id", "ts_ms", "interval_ms", "source", "record_key", "idx", "received_at",
                          "timing_basis", "quality", "batch_id"],
        "motion_epoch": ["device_id", "ts_ms", "epoch_ms", "activity", "sample_count", "source", "quality", "batch_id",
                         "device_time_raw"],   // schema v2
        "aux_measurement": ["device_id", "ts_ms", "kind", "value", "source", "validated", "quality", "batch_id"],
        "raw_frame": ["id", "device_id", "received_at", "characteristic", "bytes", "parse_status"],
        "connection_event": ["id", "device_id", "ts_ms", "kind", "detail"],
        "sync_cursor": ["device_id", "adapter_id", "opaque", "newest_record_ms", "last_complete_ms", "updated_at"],
        "sync_run": ["id", "device_id", "started_at", "ended_at", "status", "batches", "records_inserted",
                     "duplicates", "malformed_frames", "note"],
        "session": ["id", "kind", "start_ms", "end_ms", "origin", "label", "device_id", "detector", "confidence",
                    "created_at", "updated_at", "deleted"],
        "user_correction": ["id", "session_id", "field", "old_value", "new_value", "created_at"],
        "derived_metric": ["metric_id", "spec_version", "start_ms", "end_ms", "value", "unit", "availability",
                           "coverage", "confidence", "inputs_json", "computed_at"],
        "setting": ["key", "value"],
    ]

    /// Columns the spec says hold epoch-millisecond timestamps (must be INTEGER).
    static let timestampColumns: [String: [String]] = [
        "device": ["first_seen", "last_connected"],
        "ingest_batch": ["created_at"],
        "hr_sample": ["ts_ms", "received_at"],
        "beat_interval": ["ts_ms", "received_at"],
        "motion_epoch": ["ts_ms"],
        "aux_measurement": ["ts_ms"],
        "raw_frame": ["received_at"],
        "connection_event": ["ts_ms"],
        "sync_cursor": ["newest_record_ms", "last_complete_ms", "updated_at"],
        "sync_run": ["started_at", "ended_at"],
        "session": ["start_ms", "end_ms", "created_at", "updated_at"],
        "user_correction": ["created_at"],
        "derived_metric": ["start_ms", "end_ms", "computed_at"],
    ]

    @Test func everyTableHasExactlyTheSpecifiedColumns() throws {
        let store = try makeStore()
        try store.withConnectionForTesting { db in
            let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) })
            #expect(advSpecTables.isSubset(of: tables))
            for (table, expected) in Self.specColumns {
                let actual = try advColumns(db, table).map(\.name)
                #expect(Set(actual) == Set(expected), "columns of \(table)")
            }
            for (table, columns) in Self.timestampColumns {
                let info = Dictionary(uniqueKeysWithValues: try advColumns(db, table).map { ($0.name, $0) })
                for column in columns {
                    #expect(info[column]?.type == "INTEGER", "\(table).\(column) must be INTEGER epoch ms")
                }
            }
        }
    }

    @Test func nullabilityDefaultsAndKeysFollowTheSpec() throws {
        let store = try makeStore()
        try store.withConnectionForTesting { db in
            func column(_ table: String, _ name: String) throws -> AdvColumn {
                try #require(try advColumns(db, table).first { $0.name == name }, "\(table).\(name)")
            }
            #expect(try column("hr_sample", "bpm").notNull)
            #expect(try column("hr_sample", "bpm").type == "INTEGER")
            #expect(try column("beat_interval", "interval_ms").notNull)
            #expect(try column("beat_interval", "interval_ms").type == "REAL")
            #expect(try !column("hr_sample", "device_time_raw").notNull)
            #expect(try !column("hr_sample", "clock_offset_ms").notNull)
            #expect(try !column("derived_metric", "value").notNull)
            #expect(try !column("derived_metric", "coverage").notNull)
            #expect(try column("session", "deleted").defaultValue == "0")
            let derivedKey = try advColumns(db, "derived_metric").filter { $0.primaryKeyPosition > 0 }
                .sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }.map(\.name)
            #expect(derivedKey == ["metric_id", "spec_version", "start_ms", "end_ms"])
            for (table, key) in [("device", "id"), ("sync_cursor", "device_id"), ("setting", "key"),
                                 ("session", "id"), ("raw_frame", "id")] {
                #expect(try column(table, key).primaryKeyPosition == 1, "\(table) primary key")
            }
        }
    }

    @Test func measurementDedupKeysAreUniqueConstraints() throws {
        let store = try makeStore()
        try store.withConnectionForTesting { db in
            let keys: [String: Set<String>] = [
                "hr_sample": ["device_id", "source", "ts_ms"],
                "beat_interval": ["device_id", "source", "record_key", "idx"],
                "motion_epoch": ["device_id", "source", "ts_ms", "epoch_ms"],
                "aux_measurement": ["device_id", "source", "kind", "ts_ms"],
            ]
            for (table, key) in keys {
                let uniques = try advIndexes(db, table).filter(\.unique).map { Set($0.columns) }
                #expect(uniques.contains(key), "UNIQUE\(key.sorted()) on \(table)")
            }
            // Schema v2: band records are also unique by their raw device time.
            for table in ["hr_sample", "motion_epoch"] {
                let uniques = try advIndexes(db, table).filter(\.unique).map { Set($0.columns) }
                #expect(uniques.contains(["device_id", "source", "device_time_raw"]), "raw-identity key on \(table)")
            }
        }
    }

    @Test func specifiedIndexesExistWithTheirColumnOrder() throws {
        let store = try makeStore()
        try store.withConnectionForTesting { db in
            for table in ["hr_sample", "beat_interval", "motion_epoch", "aux_measurement"] {
                let lists = try advIndexes(db, table).map(\.columns)
                #expect(lists.contains(["ts_ms"]), "(ts_ms) index on \(table)")
                #expect(lists.contains(["device_id", "ts_ms"]), "(device_id, ts_ms) index on \(table)")
            }
            #expect(try advIndexes(db, "session").map(\.columns).contains(["kind", "start_ms"]))
            #expect(try advIndexes(db, "raw_frame").map(\.columns).contains(["received_at"]))
            #expect(try advIndexes(db, "connection_event").map(\.columns).contains(["ts_ms"]))
        }
    }

    @Test func tableCountsCoversEverySpecifiedTable() throws {
        let counts = try makeStore().tableCounts()
        #expect(advSpecTables.isSubset(of: Set(counts.keys)))
        #expect(counts.values.allSatisfy { $0 == 0 })
    }
}

// MARK: - Migrations and opening hostile files

@Suite("Adversarial: migrations and hostile files")
struct AdversarialMigrationTests {
    @Test func maximalUserVersionIsRefusedAndTheDataIsLeftAlone() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("max.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 61), hr(t0 + 1, 62)]))
            store.close()
        }
        do { try SQLiteConnection(path: path).setUserVersion(Int(Int32.max)) }
        for _ in 0..<2 {
            #expect(throws: StoreError.schemaTooNew(found: Int(Int32.max), supported: FormaStore.schemaVersion)) {
                _ = try FormaStore(path: path)
            }
        }
        let raw = try SQLiteConnection(path: path)
        #expect(try raw.userVersion() == Int(Int32.max))
        #expect(try raw.scalarInt64("SELECT COUNT(*) FROM hr_sample") == 2)
    }

    @Test func schemaVersionIsTheNewestMigration() throws {
        let store = try makeStore()
        #expect(FormaStore.schemaVersion >= 1)
        #expect(try store.withConnectionForTesting { try $0.userVersion() } == FormaStore.schemaVersion)
    }

    @Test func garbageFileIsRefusedAndNotOverwritten() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("garbage.sqlite")
        let garbage = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 &* 167 &+ 13) })
        try garbage.write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { _ = try FormaStore(path: path) }
        #expect(advFileBytes(path) == garbage)
    }

    @Test func textFileThatLooksLikeABackupIsRefusedAndNotOverwritten() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("notes.sqlite")
        let content = Data((advHeaderLine + "\n" + advHRLine(t0) + "\n").utf8)
        try content.write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { _ = try FormaStore(path: path) }
        #expect(advFileBytes(path) == content)
    }

    @Test func directoryPathIsRefusedWithoutTouchingItsContents() throws {
        let directory = try TemporaryDirectory()
        let inner = directory.url.appendingPathComponent("db-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let keep = inner.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        #expect(throws: (any Error).self) { _ = try FormaStore(path: inner.path(percentEncoded: false)) }
        #expect(FileManager.default.fileExists(atPath: keep.path(percentEncoded: false)))
    }

    @Test func truncatedDatabaseNeverCrashes() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("truncated.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            _ = try store.ingest(IngestBatch(provenance: provenance(),
                                             heartRates: (0..<5_000).map { hr(t0 + Int64($0) * 1_000, 60 + $0 % 40) }))
            store.close()
        }
        let full = advFileBytes(path)
        #expect(full.count > 20_000)
        try full.prefix(full.count / 2).write(to: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        // Opening may fail or succeed; reads may fail. None of it may trap.
        if let store = try? FormaStore(path: path, timeSource: ManualTimeSource(t0)) {
            _ = try? store.heartRates(in: everything)
            _ = try? store.tableCounts()
            _ = try? store.dataBounds()
            _ = try? store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0 - 1, 60)]))
        }
    }

    @Test func repeatedReopeningIsIdempotent() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("reopen.sqlite")
        var snapshots: [[String]] = []
        for round in 0..<5 {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0 + Int64(round), 60)]))
            snapshots.append(try store.withConnectionForTesting { db in
                try db.query("SELECT type || ':' || name || ':' || COALESCE(sql, '') FROM sqlite_master ORDER BY name") {
                    $0.string(0)
                }
            })
            #expect(try store.heartRates(in: everything).count == round + 1)
            #expect(try store.withConnectionForTesting { try $0.userVersion() } == FormaStore.schemaVersion)
            store.close()
        }
        #expect(Set(snapshots.map { $0.joined(separator: "\n") }).count == 1)
    }

    @Test func deleteAllDataKeepsTheSchemaVersionAcrossReopen() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("wiped.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)]))
            try store.deleteAllData()
            store.close()
        }
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        #expect(try reopened.withConnectionForTesting { try $0.userVersion() } == FormaStore.schemaVersion)
        #expect(try reopened.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)])).inserted == 1)
    }
}

// MARK: - Ingest

private struct AdvHRKey: Hashable {
    let device: String
    let source: MeasurementSource
    let ts: EpochMillis
}

@Suite("Adversarial: ingest")
struct AdversarialIngestTests {
    @Test func failingCursorWriteRollsBackEveryRecordOfTheBatch() throws {
        let store = try makeStore()
        let original = cursor(newest: t0 - 1, opaque: [1])
        _ = try store.ingest(IngestBatch(provenance: provenance(), cursor: original))
        try store.withConnectionForTesting { db in
            try db.execute("""
                CREATE TRIGGER adv_fail_cursor_insert BEFORE INSERT ON sync_cursor
                BEGIN SELECT RAISE(ABORT, 'cursor write failed'); END;
                CREATE TRIGGER adv_fail_cursor_update BEFORE UPDATE ON sync_cursor
                BEGIN SELECT RAISE(ABORT, 'cursor write failed'); END;
                """)
        }
        let before = try store.tableCounts()
        let batch = IngestBatch(
            provenance: provenance(),
            heartRates: (0..<50).map { hr(t0 + Int64($0) * 1_000, 60) },
            beatIntervals: (0..<50).map { rr(t0 + Int64($0) * 1_000, 1_000, recordKey: t0 + Int64($0) * 1_000, index: 0) },
            motion: (0..<10).map { motionEpoch(t0 + Int64($0) * 60_000, activity: 0.1) },
            aux: [auxMeasurement(t0, .batteryPercent, 50)],
            cursor: cursor(newest: t0 + 49_000, opaque: [2]))
        #expect(throws: SQLiteError.self) { try store.ingest(batch) }
        #expect(try store.tableCounts() == before)
        #expect(try store.syncCursor(deviceID: deviceA) == original)
        try store.withConnectionForTesting { db in
            try db.execute("DROP TRIGGER adv_fail_cursor_insert; DROP TRIGGER adv_fail_cursor_update;")
        }
        // Nothing of the failed attempt survived, so the retry stores everything as new.
        let retry = try store.ingest(batch)
        #expect(retry.inserted == 111)
        #expect(retry.duplicates == 0)
        #expect(try store.syncCursor(deviceID: deviceA) == cursor(newest: t0 + 49_000, opaque: [2]))
    }

    @Test func failingProvenanceWriteStoresNothing() throws {
        let store = try makeStore()
        try store.withConnectionForTesting { db in
            try db.execute("CREATE TRIGGER adv_fail_batch BEFORE INSERT ON ingest_batch BEGIN SELECT RAISE(ABORT, 'no'); END;")
        }
        #expect(throws: SQLiteError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)], cursor: cursor(newest: t0)))
        }
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
        #expect(try store.syncCursor(deviceID: deviceA) == nil)
    }

    @Test func everyKindOfInvalidRecordAnywhereInTheBatchWritesNothing() throws {
        let store = try makeStore()
        let original = cursor(newest: t0, opaque: [9])
        _ = try store.ingest(IngestBatch(provenance: provenance(), cursor: original))
        let before = try store.tableCounts()
        let good = IngestBatch(provenance: provenance(), heartRates: (0..<20).map { hr(t0 + Int64($0), 60) },
                               beatIntervals: [rr(t0, 800, recordKey: t0, index: 0)],
                               motion: [motionEpoch(t0, activity: 0.2)],
                               aux: [auxMeasurement(t0, .spo2Percent, 97)],
                               cursor: cursor(newest: t0 + 20, opaque: [10]))
        var variants: [(String, IngestBatch)] = []
        for bad in [Double.nan, -Double.nan, .signalingNaN, .infinity, -.infinity] {
            var a = good
            a.beatIntervals.append(rr(t0 + 1, bad, recordKey: t0, index: 1))
            variants.append(("interval \(bad)", a))
            var b = good
            b.motion.insert(motionEpoch(t0 + 60_000, activity: bad), at: 0)
            variants.append(("activity \(bad)", b))
            var c = good
            c.aux.append(auxMeasurement(t0 + 1, .skinTemperatureCelsius, bad))
            variants.append(("aux value \(bad)", c))
        }
        var d = good
        d.heartRates.append(hr(t0 + 99, 60, device: ""))
        variants.append(("empty heart-rate device", d))
        var e = good
        e.beatIntervals.insert(rr(t0, 800, recordKey: 1, index: 0, device: ""), at: 0)
        variants.append(("empty interval device", e))
        var f = good
        f.motion.append(motionEpoch(t0 + 1, activity: 0.1, device: ""))
        variants.append(("empty motion device", f))
        var g = good
        g.aux.append(auxMeasurement(t0 + 1, .batteryPercent, 3, device: ""))
        variants.append(("empty aux device", g))
        var h = good
        h.cursor = SyncCursor(deviceID: "", adapterID: "whoop5", opaque: nil, newestPersistedRecordTime: nil,
                              lastCompleteSyncAt: nil, updatedAt: t0)
        variants.append(("empty cursor device", h))
        variants.append(("empty provenance device",
                         IngestBatch(provenance: provenance(""), heartRates: [hr(t0, 60, device: "")])))
        for (name, batch) in variants {
            #expect(throws: (any Error).self, "\(name)") { try store.ingest(batch) }
            #expect(try store.tableCounts() == before, "\(name)")
            #expect(try store.syncCursor(deviceID: deviceA) == original, "\(name)")
        }
        #expect(try store.ingest(good).inserted == 23)
    }

    @Test func dedupKeepsTheFirstCopyAndItsBatchWhileOtherKeyPartsStayDistinct() throws {
        let store = try makeStore()
        let first = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)],
                                                 beatIntervals: [rr(t0, 800, recordKey: 7, index: 0)],
                                                 motion: [motionEpoch(t0, activity: 0.1)],
                                                 aux: [auxMeasurement(t0, .batteryPercent, 50)]))
        // Same dedup keys, different payloads: the stored copies must not change.
        let second = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 99)],
                                                  beatIntervals: [rr(t0 + 999, 1_234, recordKey: 7, index: 0)],
                                                  motion: [motionEpoch(t0, activity: 0.9)],
                                                  aux: [auxMeasurement(t0, .batteryPercent, 10)]))
        #expect(second.inserted == 0)
        #expect(second.duplicates == 4)
        #expect(try store.heartRates(in: everything).map { [$0.bpm, Int($0.batchID ?? -1)] } == [[60, Int(first.batchID)]])
        let interval = try #require(try store.beatIntervals(in: everything).first)
        #expect(interval.intervalMillis == 800 && interval.timestamp == t0 && interval.batchID == first.batchID)
        #expect(try store.motion(in: everything).map(\.activity) == [0.1])
        #expect(try store.aux(in: everything).map(\.value) == [50])
        // Any differing key component makes a distinct record.
        let third = try store.ingest(IngestBatch(
            provenance: provenance(),
            heartRates: [hr(t0, 61, source: .liveVendorStream), hr(t0, 62, source: .standardHeartRateService)],
            beatIntervals: [rr(t0, 800, recordKey: 7, index: 1), rr(t0, 800, recordKey: 8, index: 0),
                            rr(t0, 800, recordKey: 7, index: 0, source: .liveVendorStream)],
            motion: [MotionEpoch(deviceID: deviceA, timestamp: t0, epochMillis: 60_000, activity: 0.1, sampleCount: 1,
                                 source: .deviceHistory)],
            aux: [auxMeasurement(t0, .spo2Percent, 50)]))
        #expect(third.inserted == 7)
        #expect(third.duplicates == 0)
    }

    @Test func deviceIdentifiersAreStoredAndFilteredByteExactly() throws {
        let store = try makeStore()
        let ids = ["band_1", "bandX1", "Band_1", "band%1", "band-1 ", " band-1", "x\u{0}1", "x\u{0}2",
                   "a'); DROP TABLE hr_sample; --", "\u{1F4A9}\"\\\n\r\t,"]
        for id in ids {
            let result = try store.ingest(IngestBatch(provenance: provenance(id), heartRates: [hr(t0, 60, device: id)]))
            #expect(result.inserted == 1, "\(id.debugDescription)")
        }
        #expect(try store.heartRates(in: everything).count == ids.count)
        for id in ids {
            let rows = try store.heartRates(in: everything, deviceID: id)
            #expect(rows.count == 1, "\(id.debugDescription)")
            #expect(rows.first.map { Array($0.deviceID.utf8) } == Array(id.utf8))
            #expect(try store.newestSampleTime(deviceID: id) == t0)
        }
        #expect(try store.newestSampleTime(deviceID: "band") == nil)
        #expect(try store.heartRates(in: everything, deviceID: "band%").isEmpty)
        #expect(try store.heartRates(in: everything, deviceID: "x").isEmpty)
        #expect(try store.tableCounts()["hr_sample"] == ids.count)
    }

    @Test func flaggedImplausibleAndUnknownBitValuesAreStoredUntouched() throws {
        let store = try makeStore()
        let weird = QualityFlags(rawValue: Int64.min | 0x7F00 | QualityFlags.outOfRange.rawValue)
        let samples = [hr(t0, 0, quality: [.deviceMarkedInvalid]), hr(t0 + 1, 250, quality: [.outOfRange]),
                       hr(t0 + 2, 61, quality: weird), hr(t0 + 3, 20, quality: [.outOfRange, .noSensorContact])]
        let intervals = [rr(t0, 5_000, recordKey: 1, index: 0, quality: [.outOfRange]),
                         rr(t0 + 1, 0.5, recordKey: 1, index: 1, quality: weird)]
        let epochs = [MotionEpoch(deviceID: deviceA, timestamp: t0, epochMillis: 1_000, activity: 0, sampleCount: 0,
                                  source: .deviceHistory, quality: [.deviceMarkedInvalid])]
        let aux = [auxMeasurement(t0, .skinTemperatureCelsius, 45.5), auxMeasurement(t0, .respiratoryRateBrpm, 0),
                   AuxMeasurement(deviceID: deviceA, timestamp: t0 + 1, kind: .skinContact, value: 1,
                                  source: .deviceHistory, validated: true, quality: weird)]
        let result = try store.ingest(IngestBatch(provenance: provenance(), heartRates: samples, beatIntervals: intervals,
                                                  motion: epochs, aux: aux))
        #expect(result.inserted == 10)
        #expect(withoutBatch(try store.heartRates(in: everything)) == samples)
        #expect(withoutBatch(try store.beatIntervals(in: everything)) == intervals)
        #expect(withoutBatch(try store.motion(in: everything)) == epochs)
        #expect(Set(withoutBatch(try store.aux(in: everything))) == Set(aux))
    }

    @Test func extremeTimestampsAndNumbersRoundTripWithoutTrapping() throws {
        let store = try makeStore()
        let times: [EpochMillis] = [.min, .min + 1, -3_155_760_000_000, -1, 0, 1, .max - 1]
        let doubles: [Double] = [.greatestFiniteMagnitude, .leastNonzeroMagnitude, -.greatestFiniteMagnitude, 1e-300,
                                 0, 123.456, .ulpOfOne]
        // Each band record needs its own raw device time (schema v2 identity); the values stay extreme.
        let raws: [Int64] = [.min, .min + 1, -1, 0, 1, .max - 1, .max]
        let samples = times.enumerated().map { i, t in
            HeartRateSample(deviceID: deviceA, timestamp: t, bpm: 60 + i, source: .deviceHistory,
                            deviceTimeRaw: raws[i], receivedAt: t,
                            clockOffsetMillis: i % 2 == 0 ? .max : .min)
        }
        let intervals = zip(times, doubles).map { t, d in
            BeatInterval(deviceID: deviceA, timestamp: t, intervalMillis: d, source: .deviceHistory, recordKey: t,
                         indexInRecord: Int.max, receivedAt: t, timingBasis: .reconstructedFromReceiveTime)
        }
        let epochs = zip(times, doubles).map { t, d in
            MotionEpoch(deviceID: deviceA, timestamp: t, epochMillis: .max, activity: d, sampleCount: Int.max,
                        source: .deviceHistory)
        }
        let aux = zip(times, doubles).map { t, d in
            AuxMeasurement(deviceID: deviceA, timestamp: t, kind: .skinTemperatureCelsius, value: d,
                           source: .deviceHistory, validated: false)
        }
        let result = try store.ingest(IngestBatch(provenance: provenance(), heartRates: samples, beatIntervals: intervals,
                                                  motion: epochs, aux: aux))
        #expect(result.inserted == 28)
        #expect(withoutBatch(try store.heartRates(in: everything)) == samples)
        #expect(withoutBatch(try store.beatIntervals(in: everything)).map(\.intervalMillis.bitPattern) == doubles.map(\.bitPattern))
        #expect(withoutBatch(try store.motion(in: everything)) == epochs)
        #expect(withoutBatch(try store.aux(in: everything)).map(\.value.bitPattern) == doubles.map(\.bitPattern))
        #expect(try store.heartRates(in: TimeRange(start: .min, end: .min + 1)).map(\.bpm) == [60])
        #expect(try store.newestSampleTime() == .max - 1)
        let bounds = try #require(try store.dataBounds())
        #expect(bounds.start == .min)
        #expect(bounds.contains(.max - 1))
    }

    @Test func nilZeroAndEmptyStayDistinct() throws {
        let store = try makeStore()
        let zero = HeartRateSample(deviceID: deviceA, timestamp: t0, bpm: 60, source: .deviceHistory, deviceTimeRaw: 0,
                                   receivedAt: 0, clockOffsetMillis: 0)
        let none = HeartRateSample(deviceID: deviceA, timestamp: t0 + 1, bpm: 60, source: .deviceHistory,
                                   deviceTimeRaw: nil, receivedAt: t0, clockOffsetMillis: nil)
        let emptyCursor = SyncCursor(deviceID: deviceA, adapterID: "whoop5", opaque: Data(), newestPersistedRecordTime: 0,
                                     lastCompleteSyncAt: 0, updatedAt: 0)
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [none, zero], cursor: emptyCursor))
        #expect(withoutBatch(try store.heartRates(in: everything)) == [zero, none])
        #expect(try store.syncCursor(deviceID: deviceA) == emptyCursor)
        let nilCursor = SyncCursor(deviceID: deviceB, adapterID: "std", opaque: nil, newestPersistedRecordTime: nil,
                                   lastCompleteSyncAt: nil, updatedAt: t0)
        _ = try store.ingest(IngestBatch(provenance: provenance(deviceB), cursor: nilCursor))
        #expect(try store.syncCursor(deviceID: deviceB) == nilCursor)
        #expect(try store.syncCursor(deviceID: "band-C") == nil)
    }

    @Test(arguments: [UInt64(11), 12, 13])
    func randomizedRepeatedDownloadsMatchAReferenceModel(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let store = try makeStore()
        let devices = [deviceA, deviceB]
        let sources: [MeasurementSource] = [.deviceHistory, .liveVendorStream, .standardHeartRateService]
        var reference: [AdvHRKey: Int] = [:]
        var total = 0
        var inserted = 0
        var duplicates = 0
        for _ in 0..<40 {
            let device = devices[Int.random(in: 0..<devices.count, using: &rng)]
            let count = Int.random(in: 0...60, using: &rng)
            var samples: [HeartRateSample] = []
            var expectedInserted = 0
            for _ in 0..<count {
                let source = sources[Int.random(in: 0..<sources.count, using: &rng)]
                let ts = t0 + Int64.random(in: 0..<150, using: &rng) * 1_000
                let bpm = Int.random(in: 40...180, using: &rng)
                samples.append(hr(ts, bpm, device: device, source: source))
                let key = AdvHRKey(device: device, source: source, ts: ts)
                if reference[key] == nil {
                    reference[key] = bpm
                    expectedInserted += 1
                }
            }
            let result = try store.ingest(IngestBatch(provenance: provenance(device), heartRates: samples))
            #expect(result.inserted == expectedInserted)
            #expect(result.inserted + result.duplicates == count)
            total += count
            inserted += result.inserted
            duplicates += result.duplicates
        }
        #expect(inserted == reference.count)
        #expect(duplicates == total - reference.count)
        let stored = try store.heartRates(in: everything)
        #expect(stored.count == reference.count)
        #expect(stored.map(\.timestamp) == stored.map(\.timestamp).sorted())
        var storedModel: [AdvHRKey: Int] = [:]
        for sample in stored { storedModel[AdvHRKey(device: sample.deviceID, source: sample.source, ts: sample.timestamp)] = sample.bpm }
        #expect(storedModel == reference)
        for _ in 0..<60 {
            let start = t0 + Int64.random(in: -5...155, using: &rng) * 1_000 + Int64.random(in: -1...1, using: &rng)
            let range = TimeRange(start: start, end: start + Int64.random(in: 0...40_000, using: &rng))
            let device: String? = Bool.random(using: &rng) ? nil : devices[Int.random(in: 0..<2, using: &rng)]
            var sourceSet: Set<MeasurementSource>? = Set(sources.filter { _ in Bool.random(using: &rng) })
            if sourceSet?.isEmpty == true || Bool.random(using: &rng) { sourceSet = nil }
            let got = try store.heartRates(in: range, deviceID: device, sources: sourceSet)
            let want = Set(reference.keys.filter {
                range.contains($0.ts) && (device == nil || $0.device == device) && (sourceSet?.contains($0.source) ?? true)
            })
            #expect(Set(got.map { AdvHRKey(device: $0.deviceID, source: $0.source, ts: $0.timestamp) }) == want)
            #expect(got.count == want.count)
            #expect(got.map(\.timestamp) == got.map(\.timestamp).sorted())
        }
    }

    @Test func outOfOrderBatchesReadBackTimeSortedInEveryTable() throws {
        var rng = SplitMix64(seed: 99)
        let store = try makeStore()
        let timestamps = (0..<400).map { t0 + Int64($0) * 997 }.shuffled(using: &rng)
        for chunk in stride(from: 0, to: timestamps.count, by: 40) {
            let slice = timestamps[chunk..<chunk + 40]
            _ = try store.ingest(IngestBatch(provenance: provenance(),
                                             heartRates: slice.map { hr($0, 60) },
                                             beatIntervals: slice.map { rr($0, 900, recordKey: $0, index: 0) },
                                             motion: slice.map { motionEpoch($0, activity: 0.5) },
                                             aux: slice.map { auxMeasurement($0, .batteryPercent, 80) }))
        }
        let sorted = timestamps.sorted()
        #expect(try store.heartRates(in: everything).map(\.timestamp) == sorted)
        #expect(try store.beatIntervals(in: everything).map(\.timestamp) == sorted)
        #expect(try store.motion(in: everything).map(\.timestamp) == sorted)
        #expect(try store.aux(in: everything).map(\.timestamp) == sorted)
        #expect(try store.aux(in: everything, kinds: [.batteryPercent]).count == 400)
        #expect(try store.aux(in: everything, kinds: [.spo2Percent]).isEmpty)
    }

    @Test func rangeQueriesAreHalfOpen() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(.min, 60), hr(t0, 61), hr(t0 + 1_000, 62)]))
        #expect(try store.heartRates(in: TimeRange(start: t0, end: t0 + 1_000)).map(\.bpm) == [61])
        #expect(try store.heartRates(in: TimeRange(start: t0 + 1, end: t0 + 1_001)).map(\.bpm) == [62])
        #expect(try store.heartRates(in: TimeRange(start: t0, end: t0)).isEmpty)
        #expect(try store.heartRates(in: TimeRange(start: t0 + 2_000, end: t0)).isEmpty)
        #expect(try store.heartRates(in: TimeRange(start: .min, end: .min + 1)).map(\.bpm) == [60])
    }

    @Test func dataBoundsSpanEveryMeasurementTable() throws {
        let store = try makeStore()
        #expect(try store.dataBounds() == nil)
        #expect(try store.newestSampleTime() == nil)
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)],
                                         beatIntervals: [rr(t0 + 5 * advHour, 900, recordKey: 1, index: 0)],
                                         motion: [motionEpoch(t0 - 3 * advHour, activity: 0.1)],
                                         aux: [auxMeasurement(t0 + advHour, .batteryPercent, 70)]))
        let bounds = try #require(try store.dataBounds())
        for t in [t0, t0 + 5 * advHour, t0 - 3 * advHour, t0 + advHour] {
            #expect(bounds.contains(t))
        }
        #expect(try store.newestSampleTime(deviceID: deviceA) ?? .min >= t0)
        #expect(try store.newestSampleTime(deviceID: deviceB) == nil)
    }

    @Test func aHugeSingleBatchIsAtomicExactAndIdempotent() throws {
        let store = try makeStore()
        let n = 60_000
        let samples = (0..<n).map { hr(t0 + Int64($0) * 1_000, 40 + $0 % 120) }
        let intervals = (0..<n).map { rr(t0 + Int64($0) * 1_000, 500 + Double($0 % 1_000) / 7, recordKey: t0 + Int64($0) * 1_000, index: 0) }
        var poisoned = IngestBatch(provenance: provenance(), heartRates: samples, beatIntervals: intervals)
        poisoned.aux = [auxMeasurement(t0, .batteryPercent, .nan)]
        #expect(throws: (any Error).self) { try store.ingest(poisoned) }
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
        let batch = IngestBatch(provenance: provenance(), heartRates: samples, beatIntervals: intervals)
        let first = try store.ingest(batch)
        #expect(first.inserted == 2 * n && first.duplicates == 0)
        let second = try store.ingest(batch)
        #expect(second.inserted == 0 && second.duplicates == 2 * n)
        #expect(try store.tableCounts()["hr_sample"] == n)
        #expect(try store.tableCounts()["beat_interval"] == n)
    }

    @Test func provenanceIsRecordedPerBatchAndStampedOnNewRecordsOnly() throws {
        let store = try makeStore()
        let hostile = Provenance(deviceID: deviceA, adapterID: "whoop5\"; DROP TABLE device; --", parserVersion: "9.9.9-\u{3B2}",
                                 firmwareVersion: nil, source: .liveVendorStream, syncRunID: .max, createdAt: .min,
                                 note: "line1\nline2,\"q\"\u{0}")
        let r1 = try store.ingest(IngestBatch(provenance: hostile, heartRates: [hr(t0, 60, source: .liveVendorStream)]))
        let plain = provenance(source: .liveVendorStream)
        let r2 = try store.ingest(IngestBatch(provenance: plain, heartRates: [hr(t0, 61, source: .liveVendorStream),
                                                                             hr(t0 + 1, 62, source: .liveVendorStream)]))
        #expect(r1.batchID != r2.batchID)
        #expect(try store.provenance(batchID: r1.batchID) == hostile)
        #expect(try store.provenance(batchID: r2.batchID) == plain)
        let rows = try store.heartRates(in: everything)
        #expect(rows.map(\.batchID) == [r1.batchID, r2.batchID])
        #expect(rows.map(\.bpm) == [60, 62])
        #expect(try store.tableCounts()["device"] == 0)
    }
}

// MARK: - Raw frame capture

@Suite("Adversarial: raw frame capture")
struct AdversarialRawFrameTests {
    @Test(arguments: [UInt64(1), 2, 3])
    func retentionBoundsHoldAfterEveryCaptureAndOnlyTheOldestAreDropped(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let time = ManualTimeSource(t0)
        let policy = RawFrameRetention(maxAgeMillis: 10 * 60_000, maxFrames: 25, maxTotalBytes: 2_000)
        let store = try makeStore(time: time, retention: policy)
        try store.setRawCaptureEnabled(true)
        var recorded: [Data] = []
        for i in 0..<400 {
            time.advance(byMillis: Int64.random(in: 0...30_000, using: &rng))
            let size = Int.random(in: 0...300, using: &rng)
            let bytes = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
            try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: time.now(), characteristic: "c\(i)",
                                                    bytes: bytes, parseStatus: "ok"))
            recorded.append(bytes)
            let kept = try store.rawFrames(limit: 100_000)
            #expect(kept.count <= policy.maxFrames)
            #expect(kept.reduce(0) { $0 + $1.bytes.count } <= policy.maxTotalBytes)
            #expect(kept.allSatisfy { $0.receivedAt >= time.now() - policy.maxAgeMillis })
            let ids = kept.compactMap { Int($0.characteristic.dropFirst()) }.sorted()
            #expect(ids.count == kept.count)
            #expect(ids.last == i, "the newest frame must be kept")
            if let first = ids.first {
                #expect(ids == Array(first...i), "only the oldest frames may be dropped")
            }
            for frame in kept {
                if let id = Int(frame.characteristic.dropFirst()) { #expect(frame.bytes == recorded[id]) }
            }
        }
    }

    @Test func reopeningWithASmallerFrameBoundTrimsImmediately() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("frames.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            try store.setRawCaptureEnabled(true)
            for i in 0..<10 {
                try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: t0, characteristic: "c\(i)",
                                                        bytes: Data([UInt8(i)]), parseStatus: "ok"))
            }
            store.close()
        }
        let tight = RawFrameRetention(maxAgeMillis: EpochMillis.millisPerDay, maxFrames: 3, maxTotalBytes: 1_000)
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0), rawFrameRetention: tight)
        let kept = try reopened.rawFrames(limit: 100)
        #expect(kept.count <= 3)
        #expect(kept.contains { $0.characteristic == "c9" })
    }

    // IMPLEMENTATION BUG: the spec requires raw-frame retention to be "always bounded" (max total bytes
    // included), and the store applies retention when it is opened. When the byte bound is lowered
    // between launches, enforcement keeps the newest frame unconditionally ("frames > 1" guard in
    // FormaStore.enforceRawFrameRetention), so a frame larger than the new bound stays and the stored
    // total exceeds maxTotalBytes until the next capture.
    @Test func reopeningWithASmallerByteBoundStillBoundsTheStoredBytes() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("bytes.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            try store.setRawCaptureEnabled(true)
            for i in 0..<3 {
                try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: t0, characteristic: "c\(i)",
                                                        bytes: Data(repeating: UInt8(i), count: 600), parseStatus: "ok"))
            }
            store.close()
        }
        let tight = RawFrameRetention(maxAgeMillis: EpochMillis.millisPerDay, maxFrames: 100, maxTotalBytes: 500)
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0), rawFrameRetention: tight)
        let total = try reopened.rawFrames(limit: 100).reduce(0) { $0 + $1.bytes.count }
        #expect(total <= tight.maxTotalBytes)
    }

    @Test func framesLargerThanTheByteBoundNeverBreakTheBound() throws {
        let policy = RawFrameRetention(maxAgeMillis: EpochMillis.millisPerDay, maxFrames: 1_000, maxTotalBytes: 100)
        let store = try makeStore(retention: policy)
        try store.setRawCaptureEnabled(true)
        for (i, size) in [50, 101, 100, 1, 10_000, 99, 100, 0].enumerated() {
            try store.recordRawFrame(RawFrameRecord(deviceID: nil, receivedAt: t0, characteristic: "c\(i)",
                                                    bytes: Data(repeating: 0xAB, count: size), parseStatus: "ok"))
            let total = try store.rawFrames(limit: 10_000).reduce(0) { $0 + $1.bytes.count }
            #expect(total <= policy.maxTotalBytes, "after a \(size)-byte frame")
        }
    }

    @Test func captureFollowsTheStoredSettingThroughDeleteAllData() throws {
        let store = try makeStore()
        let frame = RawFrameRecord(deviceID: deviceA, receivedAt: t0, characteristic: "2A37", bytes: Data([0x16, 0x3C]),
                                   parseStatus: "ok")
        #expect(try store.rawCaptureEnabled() == false)
        try store.recordRawFrame(frame)
        #expect(try store.rawFrames(limit: 10).isEmpty)
        try store.setRawCaptureEnabled(true)
        try store.recordRawFrame(frame)
        #expect(try store.rawFrames(limit: 10).count == 1)
        try store.deleteAllData()
        #expect(try store.rawCaptureEnabled() == false, "settings were cleared, so capture is back to its default")
        try store.recordRawFrame(frame)
        #expect(try store.rawFrames(limit: 10).isEmpty)
        try store.setRawCaptureEnabled(true)
        try store.deleteAllData(keepSettings: true)
        #expect(try store.rawCaptureEnabled())
        #expect(try store.rawFrames(limit: 10).isEmpty)
        try store.recordRawFrame(frame)
        #expect(try store.rawFrames(limit: 10).count == 1)
        try store.setRawCaptureEnabled(false)
        try store.recordRawFrame(frame)
        #expect(try store.rawFrames(limit: 10).count == 1)
    }

    @Test func emptyAndBinaryPayloadsAreKeptByteExact() throws {
        let store = try makeStore()
        try store.setRawCaptureEnabled(true)
        let payloads = [Data(), Data([0]), Data(0...255), Data(repeating: 0, count: 517)]
        for (i, payload) in payloads.enumerated() {
            try store.recordRawFrame(RawFrameRecord(deviceID: i == 0 ? nil : "d\u{0}\(i)", receivedAt: t0 + Int64(i),
                                                    characteristic: "char-\(i)", bytes: payload,
                                                    parseStatus: "status \"\(i)\""))
        }
        let frames = try store.rawFrames(limit: 100)
        #expect(frames.count == payloads.count)
        for frame in frames {
            let i = try #require(Int(frame.characteristic.dropFirst(5)))
            #expect(frame.bytes == payloads[i])
            #expect(frame.deviceID == (i == 0 ? nil : "d\u{0}\(i)"))
            #expect(frame.parseStatus == "status \"\(i)\"")
        }
    }

    @Test func logQueriesAreTimeSortedHonourTheLimitAndSurviveHostileLimits() throws {
        var rng = SplitMix64(seed: 5)
        let store = try makeStore()
        try store.setRawCaptureEnabled(true)
        let times = (0..<30).map { t0 + Int64($0) * 1_000 }.shuffled(using: &rng)
        for (i, t) in times.enumerated() {
            try store.recordConnectionEvent(ConnectionEvent(deviceID: i % 3 == 0 ? nil : deviceA, timestamp: t,
                                                            kind: .connected, detail: i % 2 == 0 ? nil : "d\(i)"))
            let id = try store.beginSyncRun(SyncRunRecord(deviceID: deviceA, startedAt: t, status: .running))
            try store.finishSyncRun(SyncRunRecord(id: id, deviceID: deviceA, startedAt: t, endedAt: t + 10,
                                                  status: .completed, batches: i))
            try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: t, characteristic: "c",
                                                    bytes: Data([1]), parseStatus: "ok"))
        }
        func monotonic(_ values: [EpochMillis]) -> Bool { values == values.sorted() || values == values.sorted(by: >) }
        for limit in [1, 5, 30, 1_000] {
            let events = try store.connectionEvents(limit: limit)
            #expect(events.count == min(limit, 30))
            #expect(monotonic(events.map(\.timestamp)))
            let runs = try store.syncRuns(limit: limit)
            #expect(runs.count == min(limit, 30))
            #expect(monotonic(runs.map(\.startedAt)))
            let frames = try store.rawFrames(limit: limit)
            #expect(frames.count == min(limit, 30))
            #expect(monotonic(frames.map(\.receivedAt)))
        }
        for limit in [0, -1, Int.min, Int.max] {
            #expect(try store.connectionEvents(limit: limit).count <= 30)
            #expect(try store.syncRuns(limit: limit).count <= 30)
            #expect(try store.rawFrames(limit: limit).count <= 30)
        }
        #expect(try store.connectionEvents(limit: 0).isEmpty)
        #expect(try store.syncRuns(limit: 0).isEmpty)
        #expect(try store.rawFrames(limit: 0).isEmpty)
        let all = try store.connectionEvents(limit: 100)
        #expect(all.filter { $0.deviceID == nil }.count == 10)
        #expect(all.filter { $0.detail == nil }.count == 15)
        let open = try store.beginSyncRun(SyncRunRecord(deviceID: deviceB, startedAt: t0 + 999_999, status: .running))
        let run = try #require(try store.syncRuns(limit: 100).first { $0.id == open })
        #expect(run.endedAt == nil && run.note == nil && run.status == .running)
    }
}

// MARK: - Shared fixtures for sessions, settings and lifecycle

private func advSession(_ kind: SessionKind, _ start: EpochMillis, _ end: EpochMillis, origin: SessionOrigin = .manual,
                        label: String? = nil) -> Session {
    Session(kind: kind, range: TimeRange(start: start, end: end), origin: origin, label: label, createdAt: t0, updatedAt: t0)
}

private func advDerived(_ metric: String, _ start: EpochMillis, _ end: EpochMillis, version: Int = 1,
                        value: Double? = 1, coverage: Double? = 0.5) -> DerivedMetricRecord {
    DerivedMetricRecord(metricID: metric, specVersion: version, window: TimeRange(start: start, end: end), value: value,
                        unit: "ms", availability: "available", coverage: coverage, confidence: .moderate,
                        inputsJSON: "{}", computedAt: t0)
}

private func advStoredSession(_ store: FormaStore, _ id: Int64) throws -> Session {
    guard let session = try store.sessions(includeCandidates: true, includeDeleted: true).first(where: { $0.id == id }) else {
        throw AdvBoom()
    }
    return session
}

/// Puts at least one row into every table, with `marker` embedded in text and blob fields.
private func advPopulateEverything(_ store: FormaStore, marker: String = "marker") throws {
    try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "WHOOP \(marker)", firmwareVersion: "fw-\(marker)",
                                        firstSeen: t0))
    let runID = try store.beginSyncRun(SyncRunRecord(deviceID: deviceA, startedAt: t0, status: .running, note: "run \(marker)"))
    _ = try store.ingest(IngestBatch(
        provenance: provenance(note: "batch \(marker)"),
        heartRates: (0..<200).map { hr(t0 + Int64($0) * 1_000, 60 + $0 % 30) },
        beatIntervals: (0..<200).map { rr(t0 + Int64($0) * 1_000, 950, recordKey: Int64($0), index: 0) },
        motion: (0..<20).map { motionEpoch(t0 + Int64($0) * 60_000, activity: 0.05) },
        aux: [auxMeasurement(t0, .batteryPercent, 64)],
        cursor: SyncCursor(deviceID: deviceA, adapterID: "whoop5", opaque: Data(marker.utf8), newestPersistedRecordTime: t0,
                           lastCompleteSyncAt: t0, updatedAt: t0)))
    try store.finishSyncRun(SyncRunRecord(id: runID, deviceID: deviceA, startedAt: t0, endedAt: t0 + 1, status: .completed,
                                          batches: 1, recordsInserted: 421, note: "done \(marker)"))
    try store.setRawCaptureEnabled(true)
    try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: t0, characteristic: "char \(marker)",
                                            bytes: Data(marker.utf8), parseStatus: "ok"))
    try store.recordConnectionEvent(ConnectionEvent(deviceID: deviceA, timestamp: t0, kind: .connected, detail: "event \(marker)"))
    let sessionID = try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0, end: t0 + advHour),
                                                    origin: .detectedCandidate, label: "label \(marker)", deviceID: deviceA,
                                                    detector: "det", confidence: 0.5, createdAt: t0, updatedAt: t0))
    var edited = try advStoredSession(store, sessionID)
    edited.label = "edited \(marker)"
    try store.updateSession(edited)
    try store.putDerived([DerivedMetricRecord(metricID: "metric", specVersion: 1, window: TimeRange(start: t0, end: t0 + advHour),
                                              value: 42, unit: "ms", availability: "available", coverage: 0.9,
                                              confidence: .high, inputsJSON: "{\"note\":\"\(marker)\"}", computedAt: t0)])
    try store.setSetting("value \(marker)", forKey: "note")
    try store.setUserProfile(UserProfile(birthYear: 1980, sex: .male))
}

/// Runs `body(index)` on `count` dedicated threads (all live at once) and waits for them.
private func advRunThreads(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    let group = DispatchGroup()
    for index in 0..<count {
        group.enter()
        Thread {
            body(index)
            group.leave()
        }.start()
    }
    group.wait()
}

// MARK: - Sessions and derived metrics

@Suite("Adversarial: sessions and derived metrics")
struct AdversarialSessionDerivedTests {
    @Test func everyChangedFieldGetsExactlyOneCorrection() throws {
        let time = ManualTimeSource(t0)
        let store = try makeStore(time: time)
        let id = try store.insertSession(advSession(.workout, t0, t0 + advHour, origin: .detectedCandidate))
        var s = try advStoredSession(store, id)
        s.range = TimeRange(start: t0, end: t0 + 2 * advHour)
        time.advance(byMillis: 1)
        try store.updateSession(s)
        #expect(try store.corrections(sessionID: id).map(\.field) == ["end"])
        s = try advStoredSession(store, id)
        s.label = "Run, \"easy\"\n"
        time.advance(byMillis: 1)
        try store.updateSession(s)
        s = try advStoredSession(store, id)
        s.label = nil
        time.advance(byMillis: 1)
        try store.updateSession(s)
        s = try advStoredSession(store, id)
        s.origin = .userConfirmed
        time.advance(byMillis: 1)
        try store.updateSession(s)
        s = try advStoredSession(store, id)
        s.range = TimeRange(start: t0 - advHour, end: t0 + 2 * advHour)
        time.advance(byMillis: 1)
        try store.updateSession(s)
        s = try advStoredSession(store, id)
        time.advance(byMillis: 1)
        #expect(try store.updateSession(s) == s.range, "an unchanged edit affects only the session's own range")
        let corrections = try store.corrections(sessionID: id).sorted { $0.createdAt < $1.createdAt }
        #expect(corrections.map(\.field) == ["end", "label", "label", "origin", "start"])
        #expect(corrections.map(\.createdAt) == (1...5).map { t0 + Int64($0) })
        #expect(corrections[1].oldValue == nil && corrections[1].newValue == "Run, \"easy\"\n")
        #expect(corrections[2].oldValue == "Run, \"easy\"\n" && corrections[2].newValue == nil)
        #expect(corrections.allSatisfy { $0.oldValue != $0.newValue && $0.sessionID == id })
        let final = try advStoredSession(store, id)
        #expect(final.label == nil && final.origin == .userConfirmed)
        #expect(final.range == TimeRange(start: t0 - advHour, end: t0 + 2 * advHour))
    }

    @Test func editedRangeCoversDerivedValuesOfBothTheOldAndNewBounds() throws {
        let time = ManualTimeSource(t0)
        let store = try makeStore(time: time)
        let id = try store.insertSession(advSession(.sleep, t0, t0 + 10 * advHour, origin: .detectedCandidate))
        try store.putDerived([advDerived("sleep-hr", t0 + advHour, t0 + 2 * advHour),
                              advDerived("sleep-hr", t0 + 21 * advHour, t0 + 22 * advHour),
                              advDerived("sleep-hr", t0 + 40 * advHour, t0 + 41 * advHour)])
        var edited = try advStoredSession(store, id)
        edited.range = TimeRange(start: t0 + 20 * advHour, end: t0 + 30 * advHour)
        edited.origin = .userEdited
        time.advance(byMillis: 5_000)
        let affected = try store.updateSession(edited)
        #expect(affected.start <= t0 && affected.end >= t0 + 30 * advHour)
        try store.invalidateDerived(overlapping: affected)
        #expect(try store.derived(metricID: "sleep-hr", in: everything).map(\.window.start) == [t0 + 40 * advHour])
        let corrections = try store.corrections(sessionID: id)
        #expect(Set(corrections.map(\.field)) == ["start", "end", "origin"])
        #expect(corrections.count == 3)
        #expect(corrections.allSatisfy { $0.createdAt == t0 + 5_000 && $0.sessionID == id })
    }

    @Test func editingOrDeletingMissingSessionsNeverWritesCorrections() throws {
        let store = try makeStore()
        var ghost = advSession(.sleep, t0, t0 + advHour)
        ghost.id = 9_999
        #expect(throws: (any Error).self) { try store.updateSession(ghost) }
        ghost.id = nil
        #expect(throws: (any Error).self) { try store.updateSession(ghost) }
        _ = try? store.softDeleteSession(id: 9_999)
        _ = try? store.softDeleteSession(id: .min)
        #expect(try store.corrections().isEmpty)
        #expect(try store.sessions(includeCandidates: true, includeDeleted: true).isEmpty)
    }

    @Test func softDeletingTwiceRecordsOneCorrectionAndKeepsTheRow() throws {
        let store = try makeStore()
        let id = try store.insertSession(advSession(.workout, t0, t0 + advHour, label: "x"))
        try store.softDeleteSession(id: id)
        try store.softDeleteSession(id: id)
        #expect(try store.corrections(sessionID: id).count == 1)
        #expect(try store.sessions().isEmpty)
        let deleted = try store.sessions(includeDeleted: true)
        #expect(deleted.count == 1)
        #expect(deleted.first?.deleted == true && deleted.first?.label == "x")
    }

    @Test func nonFiniteSessionConfidenceIsRejected() throws {
        let store = try makeStore()
        for bad in [Double.nan, .infinity, -.infinity] {
            var session = advSession(.sleep, t0, t0 + advHour, origin: .detectedCandidate)
            session.confidence = bad
            #expect(throws: (any Error).self) { try store.insertSession(session) }
        }
        #expect(try store.sessions(includeDeleted: true).isEmpty)
    }

    @Test(arguments: [UInt64(21), 22])
    func sessionQueriesMatchAnOverlapModel(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let store = try makeStore()
        let origins: [SessionOrigin] = [.manual, .detectedCandidate, .userConfirmed, .userEdited, .imported]
        var model: [Session] = []
        for _ in 0..<120 {
            let start = t0 + Int64.random(in: 0..<1_000, using: &rng) * 60_000
            let end = start + Int64.random(in: 1...300, using: &rng) * 60_000
            var session = Session(kind: Bool.random(using: &rng) ? .sleep : .workout, range: TimeRange(start: start, end: end),
                                  origin: origins[Int.random(in: 0..<origins.count, using: &rng)],
                                  label: Bool.random(using: &rng) ? nil : "L\(start)", createdAt: t0, updatedAt: t0)
            let id = try store.insertSession(session)
            session.id = id
            if Int.random(in: 0..<5, using: &rng) == 0 {
                try store.softDeleteSession(id: id)
                session.deleted = true
            }
            model.append(session)
        }
        #expect(Set(model.compactMap(\.id)).count == model.count)
        let kinds: [SessionKind?] = [nil, .sleep, .workout]
        for _ in 0..<80 {
            let start = t0 + Int64.random(in: -100...1_100, using: &rng) * 60_000 + Int64.random(in: -1...1, using: &rng)
            let range = TimeRange(start: start, end: start + Int64.random(in: 1...400, using: &rng) * 60_000)
            let kind = kinds[Int.random(in: 0..<kinds.count, using: &rng)]
            let includeCandidates = Bool.random(using: &rng)
            let includeDeleted = Bool.random(using: &rng)
            let got = try store.sessions(kind: kind, in: range, includeCandidates: includeCandidates,
                                         includeDeleted: includeDeleted)
            let want = model.filter { s in
                (kind == nil || s.kind == kind) && s.range.overlaps(range)
                    && (includeCandidates || s.origin != .detectedCandidate) && (includeDeleted || !s.deleted)
            }
            #expect(Set(got.compactMap(\.id)) == Set(want.compactMap(\.id)))
            #expect(got.count == want.count)
            #expect(got.map(\.range.start) == got.map(\.range.start).sorted())
        }
        #expect(try store.sessions(includeCandidates: true, includeDeleted: true).count == model.count)
    }

    @Test(arguments: [UInt64(31), 32])
    func derivedQueriesAndInvalidationMatchAnOverlapModel(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let store = try makeStore()
        let metrics = ["rmssd", "rhr", "load"]
        var model: [DerivedMetricRecord] = []
        var keys = Set<String>()
        for _ in 0..<200 {
            let metric = metrics[Int.random(in: 0..<metrics.count, using: &rng)]
            let start = t0 + Int64.random(in: 0..<500, using: &rng) * 60_000
            let end = start + Int64.random(in: 1...240, using: &rng) * 60_000
            let version = Int.random(in: 1...2, using: &rng)
            guard keys.insert("\(metric)|\(version)|\(start)|\(end)").inserted else { continue }
            model.append(advDerived(metric, start, end, version: version,
                                    value: Bool.random(using: &rng) ? nil : Double(start % 997) / 3,
                                    coverage: Bool.random(using: &rng) ? nil : 0.25))
        }
        try store.putDerived(model)
        func randomRange() -> TimeRange {
            let start = t0 + Int64.random(in: -50...600, using: &rng) * 60_000 + Int64.random(in: -1...1, using: &rng)
            return TimeRange(start: start, end: start + Int64.random(in: 1...120, using: &rng) * 60_000)
        }
        for _ in 0..<40 {
            let range = randomRange()
            for metric in metrics {
                let got = try store.derived(metricID: metric, in: range)
                let want = model.filter { $0.metricID == metric && $0.window.overlaps(range) }
                #expect(Set(got) == Set(want))
                #expect(got.count == want.count)
                #expect(got.map(\.window.start) == got.map(\.window.start).sorted())
            }
        }
        var remaining = model
        for _ in 0..<10 {
            let range = randomRange()
            let expected = remaining.filter { $0.window.overlaps(range) }.count
            #expect(try store.invalidateDerived(overlapping: range) == expected)
            remaining.removeAll { $0.window.overlaps(range) }
            let left = try metrics.flatMap { try store.derived(metricID: $0, in: everything) }
            #expect(Set(left) == Set(remaining))
        }
    }

    @Test func derivedUpsertKeepsNilAsNilAndZeroAsZero() throws {
        let store = try makeStore()
        let window = TimeRange(start: t0, end: t0 + advHour)
        let metric = "m\u{0}\u{1F600}'; --"
        let unavailable = DerivedMetricRecord(metricID: metric, specVersion: 1, window: window, value: nil, unit: "",
                                              availability: "insufficientData", coverage: nil, confidence: .none,
                                              inputsJSON: String(repeating: "{\"k\":\"v,\\\"\"}", count: 20_000),
                                              computedAt: .min)
        let zero = DerivedMetricRecord(metricID: metric, specVersion: 2, window: window, value: 0, unit: "ms",
                                       availability: "available", coverage: 0, confidence: .low, inputsJSON: "",
                                       computedAt: .max)
        try store.putDerived([unavailable, zero])
        #expect(try store.derived(metricID: metric, in: window) == [unavailable, zero])
        var replaced = unavailable
        replaced.value = 5
        replaced.coverage = 1
        replaced.confidence = .high
        var replacedAgain = unavailable
        replacedAgain.value = 6
        try store.putDerived([replaced, replacedAgain])
        #expect(try store.derived(metricID: metric, in: window) == [replacedAgain, zero])
        #expect(try store.derived(metricID: "m", in: window).isEmpty)
    }

    @Test func nonFiniteDerivedNumbersAreRejectedAtomically() throws {
        let store = try makeStore()
        let good = advDerived("m", t0, t0 + 1)
        for bad in [Double.nan, .infinity, -.infinity] {
            var value = advDerived("m", t0 + 10, t0 + 20)
            value.value = bad
            #expect(throws: (any Error).self) { try store.putDerived([good, value]) }
            var coverage = advDerived("m", t0 + 10, t0 + 20)
            coverage.coverage = bad
            #expect(throws: (any Error).self) { try store.putDerived([good, coverage]) }
        }
        #expect(try store.derived(metricID: "m", in: everything).isEmpty)
    }
}

// MARK: - Settings

private struct AdvPreferences: Codable, Equatable {
    var name: String?
    var zones: [Int]
    var ratio: Double?
    var nested: [String: [Double]]
    var when: Date
}

@Suite("Adversarial: settings")
struct AdversarialSettingsTests {
    @Test func hostileKeysAndValuesRoundTrip() throws {
        let store = try makeStore()
        let big = String(repeating: "\u{1F600}x,\"\n", count: 200_000)
        let pairs: [(String, String)] = [("k'; DROP TABLE setting; --", "v"), ("\u{65E5}\u{672C}", ""), ("a\u{0}b", "\u{0}"),
                                         ("a\u{0}c", "different"), ("with\nnewline", "null"), (" spaced ", big),
                                         ("units", "metric")]
        for (key, value) in pairs { try store.setSetting(value, forKey: key) }
        for (key, value) in pairs { #expect(try store.setting(forKey: key) == value, "\(key.debugDescription)") }
        try store.setSetting("imperial", forKey: "units")
        #expect(try store.setting(forKey: "units") == "imperial")
        _ = try store.removeSetting(forKey: "a\u{0}b")
        #expect(try store.setting(forKey: "a\u{0}b") == nil)
        #expect(try store.setting(forKey: "a\u{0}c") == "different")
        _ = try store.removeSetting(forKey: "a\u{0}b")
        #expect(try store.setting(forKey: "never-set") == nil)
        #expect(try store.tableCounts()["setting"] == pairs.count - 1)
    }

    @Test func userProfileLivesUnderTheDocumentedKeyAsPlainJSON() throws {
        let store = try makeStore()
        #expect(try store.userProfile() == nil)
        let profile = UserProfile(birthYear: 1990, sex: .female, maxHeartRateOverride: nil, restingHeartRateOverride: 48)
        try store.setUserProfile(profile)
        let text = try #require(try store.setting(forKey: "user_profile"))
        #expect(try JSONDecoder().decode(UserProfile.self, from: Data(text.utf8)) == profile)
        let manual = UserProfile(birthYear: nil, sex: .unspecified)
        try store.setSetting(String(decoding: try JSONEncoder().encode(manual), as: UTF8.self), forKey: "user_profile")
        #expect(try store.userProfile() == manual)
        for corrupt in [#"{"birthYear":"nineteen ninety","sex":"female"}"#, #"{"sex":"robot"}"#, "", "[]", "null"] {
            try store.setSetting(corrupt, forKey: "user_profile")
            #expect(throws: (any Error).self, "\(corrupt)") { try store.userProfile() }
        }
    }

    @Test func codableSettingsRoundTripNilAndExactNumbers() throws {
        let store = try makeStore()
        let prefs = AdvPreferences(name: nil, zones: [Int.min, 0, Int.max], ratio: nil,
                                   nested: ["a": [0.1, 1e-300, 1.7976931348623157e308], "\u{0}": []],
                                   when: Date(timeIntervalSince1970: 1_772_323_200.123))
        try store.setCodableSetting(prefs, forKey: "prefs")
        #expect(try store.codableSetting(AdvPreferences.self, forKey: "prefs") == prefs)
        #expect(try store.codableSetting(AdvPreferences.self, forKey: "absent") == nil)
        try store.setCodableSetting(0.1 + 0.2, forKey: "fragment")
        #expect(try store.codableSetting(Double.self, forKey: "fragment") == 0.1 + 0.2)
        #expect(throws: (any Error).self) { try store.codableSetting(Int.self, forKey: "prefs") }
    }

    @Test func deleteAllDataKeepsOnlySettingsWhenAsked() throws {
        let store = try makeStore()
        try advPopulateEverything(store)
        try store.deleteAllData(keepSettings: true)
        var counts = try store.tableCounts()
        #expect((counts["setting"] ?? 0) > 0)
        counts["setting"] = 0
        #expect(counts.values.allSatisfy { $0 == 0 })
        #expect(try store.userProfile() == UserProfile(birthYear: 1980, sex: .male))
        #expect(try store.setting(forKey: "note") == "value marker")
        try store.deleteAllData()
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
        #expect(try store.userProfile() == nil)
        #expect(try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)])).inserted == 1)
    }
}

// MARK: - Lifecycle, deletion and persistence

@Suite("Adversarial: lifecycle")
struct AdversarialLifecycleTests {
    @Test func deleteAllDataLeavesNoTraceOfDeletedValuesInTheDatabaseFiles() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("private.sqlite")
        let marker = "FORMA-PRIVATE-7f3a91c2"
        let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        try advPopulateEverything(store, marker: marker)
        #expect(advContains(advFileBytes(path) + advFileBytes(path + "-wal"), marker), "precondition: marker reached disk")
        try store.deleteAllData()
        let files = [path, path + "-wal", path + "-shm", path + "-journal"]
        for file in files { #expect(!advContains(advFileBytes(file), marker), "\(file)") }
        store.close()
        for file in files { #expect(!advContains(advFileBytes(file), marker), "\(file) after close") }
    }

    // IMPLEMENTATION BUG: `destroyDatabaseFiles(at:)` is specified to remove the database file and its
    // -wal/-shm companions. Given a directory path (a caller mistake or a hostile value) it calls
    // FileManager.removeItem, which deletes the whole directory tree recursively instead of refusing.
    @Test func destroyDatabaseFilesNeverDeletesADirectoryTree() throws {
        let directory = try TemporaryDirectory()
        let victim = directory.path("Documents")
        try FileManager.default.createDirectory(atPath: victim, withIntermediateDirectories: true)
        let precious = victim + "/photo.jpg"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: precious))
        _ = try? FormaStore.destroyDatabaseFiles(at: victim)
        #expect(FileManager.default.fileExists(atPath: precious))
    }

    @Test func destroyDatabaseFilesRemovesEveryCompanionAndIsIdempotent() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("gone.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            try advPopulateEverything(store)
            #expect(FileManager.default.fileExists(atPath: path + "-wal"))
            store.close()
        }
        try Data("left over".utf8).write(to: URL(fileURLWithPath: path + "-wal"))
        try Data("left over".utf8).write(to: URL(fileURLWithPath: path + "-shm"))
        try FormaStore.destroyDatabaseFiles(at: path)
        for suffix in ["", "-wal", "-shm"] { #expect(!FileManager.default.fileExists(atPath: path + suffix), "\(suffix)") }
        try FormaStore.destroyDatabaseFiles(at: path)
        let fresh = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        #expect(try fresh.tableCounts().values.allSatisfy { $0 == 0 })
    }

    @Test func everyKindOfDataSurvivesReleaseAndReopen() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("persist.sqlite")
        func snapshot(_ s: FormaStore) throws -> [String] {
            [String(describing: try s.devices()), String(describing: try s.heartRates(in: everything)),
             String(describing: try s.beatIntervals(in: everything)), String(describing: try s.motion(in: everything)),
             String(describing: try s.aux(in: everything)), String(describing: try s.syncCursor(deviceID: deviceA)),
             String(describing: try s.rawFrames(limit: 1_000)), String(describing: try s.connectionEvents(limit: 1_000)),
             String(describing: try s.syncRuns(limit: 1_000)),
             String(describing: try s.sessions(includeCandidates: true, includeDeleted: true)),
             String(describing: try s.corrections()), String(describing: try s.derived(metricID: "metric", in: everything)),
             String(describing: try s.setting(forKey: "note")), String(describing: try s.userProfile()),
             String(describing: try s.rawCaptureEnabled()),
             String(describing: try s.tableCounts().sorted { $0.key < $1.key })]
        }
        var before: [String] = []
        do {
            // Released without an explicit close(): deinit must leave a consistent file.
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            try advPopulateEverything(store)
            before = try snapshot(store)
        }
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        #expect(try snapshot(reopened) == before)
    }

    @Test func closingWhileOtherThreadsIngestLeavesOnlyWholeBatches() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("closing.sqlite")
        let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        let committed = AdvLocked(0)
        let unexpected = AdvLocked<[String]>([])
        let workers = 4
        advRunThreads(workers + 1) { worker in
            if worker == workers {
                let deadline = Date().addingTimeInterval(10)
                while committed.value < 40, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                store.close()
                return
            }
            for batch in 0..<3_000 {
                let base = Int64(worker * 3_000 + batch) * 10
                do {
                    _ = try store.ingest(IngestBatch(provenance: provenance(),
                                                     heartRates: (0..<10).map { hr(t0 + (base + Int64($0)) * 1_000, 60) }))
                    committed.mutate { $0 += 1 }
                } catch let error as StoreError where error == .closed {
                    return
                } catch {
                    unexpected.mutate { $0.append(String(describing: error)) }
                    return
                }
            }
        }
        #expect(unexpected.value.isEmpty)
        #expect(!store.isOpen)
        #expect(throws: (any Error).self) { try store.heartRates(in: everything) }
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        let counts = try reopened.tableCounts()
        #expect(counts["hr_sample"] == committed.value * 10)
        #expect(counts["ingest_batch"] == committed.value)
        let perBatch = try reopened.withConnectionForTesting { db in
            try db.query("SELECT COUNT(*) FROM hr_sample GROUP BY batch_id") { $0.int(0) }
        }
        #expect(perBatch.count == committed.value)
        #expect(perBatch.allSatisfy { $0 == 10 })
    }
}

// MARK: - CSV export

private let advCSVFileNames: Set<String> = [
    "hr_samples.csv", "beat_intervals.csv", "motion_epochs.csv", "aux_measurements.csv", "sessions.csv",
    "derived_metrics.csv", "devices.csv",
]

/// Exports into a fresh temporary directory and parses every returned file with the strict RFC 4180 parser.
private func advExportCSV(_ store: FormaStore, range: TimeRange? = nil) throws -> [String: CSVTable] {
    let directory = try TemporaryDirectory()
    let urls = try store.exportCSV(to: directory.url, range: range)
    var tables: [String: CSVTable] = [:]
    for url in urls { tables[url.lastPathComponent] = try CSVTable(try readCSV(url)) }
    return tables
}

private func advColumn(_ table: CSVTable, _ match: (String) -> Bool) throws -> Int {
    let index = table.header.firstIndex(where: match)
    return try #require(index, "no matching column in \(table.header)")
}

private func advEpoch(_ year: Int64, _ month: Int64, _ day: Int64, _ hour: Int64 = 0, _ minute: Int64 = 0,
                      _ second: Int64 = 0, _ millis: Int64 = 0) -> EpochMillis {
    ((advDaysFromCivil(year, month, day) * 24 + hour) * 60 + minute) * 60_000 + second * 1_000 + millis
}

@Suite("Adversarial: CSV export")
struct AdversarialCSVTests {
    @Test func exportWritesTheSevenSpecifiedFilesWithUnitBearingHeaders() throws {
        let store = try makeStore()
        let empty = try advExportCSV(store)
        #expect(Set(empty.keys) == advCSVFileNames)
        for (name, table) in empty {
            #expect(table.rows.isEmpty, "\(name)")
            #expect(Set(table.header).count == table.header.count, "duplicate column in \(name)")
            #expect(table.header.allSatisfy { !$0.isEmpty }, "\(name)")
        }
        for name in ["hr_samples.csv", "beat_intervals.csv", "motion_epochs.csv", "aux_measurements.csv"] {
            let header = try #require(empty[name]).header
            for column in ["ts_epoch_ms", "ts_utc_iso8601", "source", "quality_flags"] {
                #expect(header.contains(column), "\(name) lacks \(column)")
            }
        }
        #expect(empty["hr_samples.csv"]?.header.contains("bpm") == true)
        #expect(empty["beat_intervals.csv"]?.header.contains("interval_ms") == true)

        try advPopulateEverything(store)
        _ = try store.ingest(IngestBatch(provenance: provenance(source: .liveVendorStream),
                                         heartRates: [hr(t0 - 1, 77, source: .liveVendorStream, quality: [.outOfRange])]))
        let full = try advExportCSV(store)
        for (name, table) in full {
            #expect(table.rows.allSatisfy { $0.count == table.header.count }, "ragged rows in \(name)")
        }
        let heartRates = try #require(full["hr_samples.csv"])
        #expect(heartRates.rows.count == 201)
        let ts = try advColumn(heartRates) { $0 == "ts_epoch_ms" }
        let flagged = try #require(heartRates.rows.first { $0[ts] == String(t0 - 1) })
        let plain = try #require(heartRates.rows.first { $0[ts] == String(t0) })
        #expect(flagged[try advColumn(heartRates) { $0 == "bpm" }] == "77")
        let source = flagged[try advColumn(heartRates) { $0 == "source" }]
        #expect(source == "1" || source.contains(MeasurementSource.liveVendorStream.description))
        let flagsColumn = try advColumn(heartRates) { $0 == "quality_flags" }
        #expect(flagged[flagsColumn] == "8" || flagged[flagsColumn].contains("outOfRange"))
        #expect(plain[flagsColumn] == "0" || plain[flagsColumn].isEmpty)
        #expect(full["beat_intervals.csv"]?.rows.count == 200)
        #expect(full["motion_epochs.csv"]?.rows.count == 20)
        #expect(full["aux_measurements.csv"]?.rows.count == 1)
        #expect(full["sessions.csv"]?.rows.count == 1)
        #expect(full["derived_metrics.csv"]?.rows.count == 1)
        #expect(full["devices.csv"]?.rows.count == 1)
    }

    @Test(arguments: [UInt64(41), 42, 43])
    func hostileTextSurvivesRFC4180QuotingExactly(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let pieces = [",", "\"", "\n", "\r", "\r\n", " ", "  ", "a", "Z", "\u{E9}", "e\u{301}", "\u{1F600}", "\t", ";", "=",
                      "\u{0}", "\"\"", ",\"", "\u{2028}", "\u{FEFF}", "-", "+", "@", "\u{7F}"]
        func randomText() -> String {
            (0..<Int.random(in: 0...12, using: &rng)).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &rng)] }.joined()
        }
        let store = try makeStore()
        var labels: [Int64: String] = [:]
        var names: [String: String] = [:]
        var inputs: [String: String] = [:]
        var units: [String: String] = [:]
        for i in 0..<60 {
            let label = randomText()
            let id = try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0 + Int64(i) * advHour,
                                                                                      end: t0 + Int64(i) * advHour + 1),
                                                     origin: .manual, label: label, createdAt: t0, updatedAt: t0))
            labels[id] = label
            let deviceID = "dev-\(i)-" + randomText()
            let name = randomText()
            try store.upsertDevice(DeviceRecord(id: deviceID, family: .whoop5, name: name, firstSeen: t0 + Int64(i)))
            names["dev-\(i)"] = name
            let json = randomText()
            let unit = randomText()
            try store.putDerived([DerivedMetricRecord(metricID: "m\(i)", specVersion: 1, window: TimeRange(start: t0, end: t0 + 1),
                                                      value: nil, unit: unit, availability: "available", coverage: nil,
                                                      confidence: .none, inputsJSON: json, computedAt: t0)])
            inputs["m\(i)"] = json
            units["m\(i)"] = unit
        }
        func same(_ a: String, _ b: String?) -> Bool { Array(a.unicodeScalars) == Array((b ?? "\u{1}missing").unicodeScalars) }
        let tables = try advExportCSV(store)
        let sessions = try #require(tables["sessions.csv"])
        let idColumn = try advColumn(sessions) { $0 == "id" }
        let labelColumn = try advColumn(sessions) { $0 == "label" }
        #expect(sessions.rows.count == 60)
        for row in sessions.rows {
            let id = try #require(Int64(row[idColumn]))
            #expect(same(row[labelColumn], labels[id]), "label \(row[labelColumn].debugDescription)")
        }
        let devices = try #require(tables["devices.csv"])
        let deviceIDColumn = try advColumn(devices) { $0 == "id" }
        let nameColumn = try advColumn(devices) { $0 == "name" }
        #expect(devices.rows.count == 60)
        for row in devices.rows {
            let key = row[deviceIDColumn].split(separator: "-", maxSplits: 2).prefix(2).joined(separator: "-")
            #expect(same(row[nameColumn], names[key]), "device name \(row[nameColumn].debugDescription)")
        }
        let derived = try #require(tables["derived_metrics.csv"])
        let metricColumn = try advColumn(derived) { $0 == "metric_id" }
        let inputsColumn = try advColumn(derived) { $0.hasPrefix("inputs") }
        let unitColumn = try advColumn(derived) { $0 == "unit" }
        #expect(derived.rows.count == 60)
        for row in derived.rows {
            #expect(same(row[inputsColumn], inputs[row[metricColumn]]))
            #expect(same(row[unitColumn], units[row[metricColumn]]))
        }
    }

    @Test func missingValuesAreEmptyCellsAndZerosAreNot() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [
            HeartRateSample(deviceID: deviceA, timestamp: t0, bpm: 60, source: .deviceHistory, deviceTimeRaw: nil,
                            receivedAt: t0, clockOffsetMillis: nil),
            HeartRateSample(deviceID: deviceA, timestamp: t0 + 1, bpm: 61, source: .deviceHistory, deviceTimeRaw: 0,
                            receivedAt: t0, clockOffsetMillis: 0),
        ]))
        try store.putDerived([advDerived("none", t0, t0 + 1, value: nil, coverage: nil),
                              advDerived("zero", t0, t0 + 1, value: 0, coverage: 0)])
        try store.insertSession(Session(kind: .sleep, range: TimeRange(start: t0, end: t0 + advHour), origin: .manual,
                                        label: nil, deviceID: nil, detector: nil, confidence: nil, createdAt: t0, updatedAt: t0))
        try store.insertSession(Session(kind: .sleep, range: TimeRange(start: t0 + advHour, end: t0 + 2 * advHour),
                                        origin: .detectedCandidate, label: "z", detector: "d", confidence: 0,
                                        createdAt: t0, updatedAt: t0))
        try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "A", firstSeen: t0, lastConnected: nil))
        try store.upsertDevice(DeviceRecord(id: deviceB, family: .whoop5, name: "B", firmwareVersion: "0", firstSeen: t0,
                                            lastConnected: 0))
        let tables = try advExportCSV(store)

        let heartRates = try #require(tables["hr_samples.csv"])
        let ts = try advColumn(heartRates) { $0 == "ts_epoch_ms" }
        let raw = try advColumn(heartRates) { $0.contains("device_time") }
        let offset = try advColumn(heartRates) { $0.contains("clock_offset") }
        let byTime = Dictionary(heartRates.rows.map { ($0[ts], $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byTime[String(t0)]?[raw] == "" && byTime[String(t0)]?[offset] == "")
        #expect(byTime[String(t0 + 1)]?[raw] == "0" && byTime[String(t0 + 1)]?[offset] == "0")

        let derived = try #require(tables["derived_metrics.csv"])
        let metric = try advColumn(derived) { $0 == "metric_id" }
        let value = try advColumn(derived) { $0 == "value" || $0.hasPrefix("value_") }
        let coverage = try advColumn(derived) { $0.hasPrefix("coverage") }
        let none = try #require(derived.rows.first { $0[metric] == "none" })
        let zero = try #require(derived.rows.first { $0[metric] == "zero" })
        #expect(none[value] == "" && none[coverage] == "")
        #expect(Double(zero[value]) == 0 && Double(zero[coverage]) == 0)

        let sessions = try #require(tables["sessions.csv"])
        let label = try advColumn(sessions) { $0 == "label" }
        let confidence = try advColumn(sessions) { $0.contains("confidence") }
        let detector = try advColumn(sessions) { $0 == "detector" }
        let manual = try #require(sessions.rows.first { $0[label].isEmpty })
        let candidate = try #require(sessions.rows.first { $0[label] == "z" })
        #expect(manual[confidence] == "" && manual[detector] == "")
        #expect(Double(candidate[confidence]) == 0)

        let devices = try #require(tables["devices.csv"])
        let id = try advColumn(devices) { $0 == "id" }
        let firmware = try advColumn(devices) { $0.hasPrefix("firmware") }
        let lastConnected = devices.header.indices.filter { devices.header[$0].contains("last_connected") }
        #expect(!lastConnected.isEmpty)
        let a = try #require(devices.rows.first { $0[id] == deviceA })
        let b = try #require(devices.rows.first { $0[id] == deviceB })
        #expect(a[firmware] == "" && b[firmware] == "0")
        #expect(lastConnected.allSatisfy { a[$0].isEmpty })
        #expect(lastConnected.allSatisfy { !b[$0].isEmpty })
    }

    @Test func isoTimestampsAreUTCAndAgreeWithTheEpochColumn() throws {
        let store = try makeStore()
        let instants: [EpochMillis] = [
            0, -1, -86_400_001, t0,
            advEpoch(2026, 3, 8, 7) - 1, advEpoch(2026, 3, 8, 7), advEpoch(2026, 3, 8, 7) + 1,
            advEpoch(2026, 3, 29, 1), advEpoch(2026, 10, 25, 1) - 1, advEpoch(2026, 10, 25, 1),
            advEpoch(2026, 11, 1, 5, 30), advEpoch(2026, 11, 1, 6, 30),
            advEpoch(2028, 2, 29, 23, 59, 59, 999), advEpoch(1900, 3, 1), advEpoch(2000, 2, 29, 12),
            advEpoch(9999, 12, 31, 23, 59, 59, 999), advEpoch(1, 1, 1),
        ]
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: instants.map { hr($0, 60) }))
        let table = try #require(try advExportCSV(store)["hr_samples.csv"])
        #expect(table.rows.count == instants.count)
        for row in 0..<table.rows.count {
            let epoch = try #require(Int64(try table.value(row, "ts_epoch_ms")))
            let iso = try table.value(row, "ts_utc_iso8601")
            #expect(advParseISO8601UTCMillis(iso) == epoch, "\(iso) should be \(epoch)")
        }
    }

    @Test(arguments: [("America/New_York", 2026, 3, 8, 23), ("America/New_York", 2026, 11, 1, 25),
                      ("Europe/Berlin", 2026, 3, 29, 23), ("Europe/Berlin", 2026, 10, 25, 25),
                      ("Asia/Kolkata", 2026, 3, 8, 24)])
    func localDaysAcrossDSTTransitionsSelectTheRightHours(_ zone: String, _ year: Int, _ month: Int, _ day: Int,
                                                          _ hours: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let store = try makeStore()
        let utcMidnight = advEpoch(Int64(year), Int64(month), Int64(day))
        let first = utcMidnight - 3 * EpochMillis.millisPerDay
        let samples = (0..<(6 * 24)).map { hr(first + Int64($0) * advHour, 60) }
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: samples))
        let localDay = LocalDay(year: year, month: month, day: day)
        let range = localDay.range(calendar: calendar)
        #expect(range.durationMillis == Int64(hours) * advHour)
        let selected = try store.heartRates(in: range)
        #expect(selected.count == hours)
        #expect(selected.allSatisfy { LocalDay($0.timestamp, calendar: calendar) == localDay })
        let night = TimeRange(start: range.start - 2 * advHour, end: range.start + 7 * advHour)
        try store.insertSession(Session(kind: .sleep, range: night, origin: .manual, createdAt: t0, updatedAt: t0))
        #expect(try store.sessions(kind: .sleep, in: range).map(\.range) == [night])
        let table = try #require(try advExportCSV(store, range: range)["hr_samples.csv"])
        let exported = try (0..<table.rows.count).map { row in
            try #require(advParseISO8601UTCMillis(try table.value(row, "ts_utc_iso8601")))
        }
        #expect(exported.sorted() == selected.map(\.timestamp))
        #expect(Set(exported).count == exported.count)
    }

    @Test func numbersAreWrittenLocaleFreeAndRoundTripExactly() throws {
        var rng = SplitMix64(seed: 2_026)
        let store = try makeStore()
        var values: [Double] = [0.1, 1.0 / 3, 1e-5, 123_456_789.125, 9_007_199_254_740_992, .leastNonzeroMagnitude, 1.7976931348623157e308,
                                -2.5e-8, 1e21, 1e22, 1_234_567.5]
        while values.count < 400 {
            let candidate = Double(bitPattern: rng.next())
            if candidate.isFinite, candidate != 0 { values.append(candidate) }
        }
        _ = try store.ingest(IngestBatch(
            provenance: provenance(),
            beatIntervals: values.enumerated().map { rr(t0 + Int64($0.offset), $0.element, recordKey: Int64($0.offset), index: 0) },
            motion: values.enumerated().map { motionEpoch(t0 + Int64($0.offset), activity: $0.element) },
            aux: values.enumerated().map { auxMeasurement(t0 + Int64($0.offset), .skinTemperatureCelsius, $0.element) }))
        let tables = try advExportCSV(store)
        let files: [(String, (String) -> Bool)] = [("beat_intervals.csv", { $0 == "interval_ms" }),
                                                   ("motion_epochs.csv", { $0.hasPrefix("activity") }),
                                                   ("aux_measurements.csv", { $0 == "value" || $0.hasPrefix("value_") })]
        for (file, match) in files {
            let table = try #require(tables[file])
            let ts = try advColumn(table) { $0 == "ts_epoch_ms" }
            let column = try advColumn(table, match)
            #expect(table.rows.count == values.count, "\(file)")
            for row in table.rows {
                let index = try #require(Int64(row[ts])) - t0
                let parsed = try #require(Double(row[column]), "\(file): \(row[column])")
                #expect(parsed.bitPattern == values[Int(index)].bitPattern, "\(file): \(row[column])")
            }
        }
    }

    @Test func extremeWindowsAndTimestampsExportWithoutTrapping() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(.min, 60), hr(.max - 6_000, 61)]))
        try store.insertSession(Session(kind: .sleep, range: TimeRange(start: .min, end: .max), origin: .manual,
                                        label: "forever", createdAt: .min, updatedAt: .max))
        try store.putDerived([advDerived("m", .min, .max)])
        try store.upsertDevice(DeviceRecord(id: deviceA, family: .unknown, name: "x", firstSeen: .min, lastConnected: .max))
        for range in [nil, everything, TimeRange(start: .min, end: .min + 1)] as [TimeRange?] {
            let tables = try advExportCSV(store, range: range)
            #expect(tables["sessions.csv"]?.rows.count == 1)
            #expect(tables["derived_metrics.csv"]?.rows.count == 1)
            #expect(tables["devices.csv"]?.rows.count == 1)
        }
        let heartRates = try #require(try advExportCSV(store)["hr_samples.csv"])
        #expect(heartRates.rows.count == 2)
        let iso = try advColumn(heartRates) { $0 == "ts_utc_iso8601" }
        #expect(heartRates.rows.allSatisfy { !$0[iso].isEmpty })
    }

    @Test func rangeLimitsMeasurementsHalfOpen() throws {
        let store = try makeStore()
        let times = [t0 - 1, t0, t0 + 999, t0 + 1_000]
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: times.map { hr($0, 60) },
                                         beatIntervals: times.map { rr($0, 900, recordKey: $0, index: 0) },
                                         motion: times.map { motionEpoch($0, activity: 0.1) },
                                         aux: times.map { auxMeasurement($0, .batteryPercent, 50) }))
        try store.insertSession(advSession(.sleep, t0 - 5_000, t0 - 1_000, label: "before"))
        try store.insertSession(advSession(.sleep, t0 + 2_000, t0 + 3_000, label: "after"))
        try store.insertSession(advSession(.sleep, t0 + 100, t0 + 200, label: "inside"))
        let tables = try advExportCSV(store, range: TimeRange(start: t0, end: t0 + 1_000))
        for name in ["hr_samples.csv", "beat_intervals.csv", "motion_epochs.csv", "aux_measurements.csv"] {
            let table = try #require(tables[name])
            let ts = try advColumn(table) { $0 == "ts_epoch_ms" }
            #expect(Set(table.rows.map { $0[ts] }) == [String(t0), String(t0 + 999)], "\(name)")
        }
        let sessions = try #require(tables["sessions.csv"])
        let label = try advColumn(sessions) { $0 == "label" }
        #expect(sessions.rows.map { $0[label] } == ["inside"])
    }

    @Test func exportIntoAnExistingFileFailsWithoutDamagingIt() throws {
        let directory = try TemporaryDirectory()
        let blocker = directory.file("not-a-directory")
        try Data("keep me".utf8).write(to: blocker)
        let store = try makeStore()
        try advPopulateEverything(store)
        #expect(throws: (any Error).self) { try store.exportCSV(to: blocker, range: nil) }
        #expect(advFileBytes(blocker.path(percentEncoded: false)) == Data("keep me".utf8))
    }

    @Test func tiedTimestampsAcrossExportPagesAreNeitherLostNorRepeated() throws {
        var rng = SplitMix64(seed: 8)
        let store = try makeStore()
        let n = 10_000
        var intervals = (0..<n).map { rr(t0, 800 + Double($0 % 500), recordKey: t0, index: $0) }
        intervals.append(rr(t0 - 1, 700, recordKey: t0 - 1, index: 0))
        intervals.append(rr(t0 + 1, 900, recordKey: t0 + 1, index: 0))
        _ = try store.ingest(IngestBatch(provenance: provenance(), beatIntervals: intervals.shuffled(using: &rng)))
        let table = try #require(try advExportCSV(store)["beat_intervals.csv"])
        #expect(table.rows.count == n + 2)
        let ts = try advColumn(table) { $0 == "ts_epoch_ms" }
        let index = try advColumn(table) { $0.contains("index") || $0 == "idx" }
        let tied = table.rows.filter { $0[ts] == String(t0) }.compactMap { Int($0[index]) }
        #expect(tied.sorted() == Array(0..<n))
    }
}

// MARK: - Backup (NDJSON)

private let advHostileStrings = [
    "plain", "", " lead", "trail ", "comma,", "quote\"", "back\\slash", "new\nline", "cr\rret", "crlf\r\nx",
    "\u{2028}\u{2029}", "nul\u{0}byte", "ctl\u{1}\u{1F}\u{7F}", "\u{FEFF}bom", "e\u{301}\u{1F9EA}\u{200D}",
    "{\"json\":true}", "</script>",
]

private func advScalars(_ text: String?) -> String {
    text.map { $0.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".") } ?? "nil"
}

private func advSessionFacts(_ s: Session) -> String {
    "\(s.kind.rawValue)|\(s.range.start)|\(s.range.end)|\(s.origin.rawValue)|\(advScalars(s.label))|"
        + "\(advScalars(s.deviceID))|\(advScalars(s.detector))|\(s.confidence.map { String($0.bitPattern) } ?? "nil")|"
        + "\(s.createdAt)|\(s.updatedAt)|\(s.deleted)"
}

private func advCorrectionFacts(_ store: FormaStore) throws -> [String] {
    var owners: [Int64: String] = [:]
    for session in try store.sessions(includeCandidates: true, includeDeleted: true) {
        if let id = session.id { owners[id] = advSessionFacts(session) }
    }
    return try store.corrections().map { c in
        "\(c.sessionID.flatMap { owners[$0] } ?? "none")#\(c.field)#\(advScalars(c.oldValue))#\(advScalars(c.newValue))#\(c.createdAt)"
    }.sorted()
}

private func advMeasurementFacts(_ store: FormaStore) throws -> [String] {
    [String(describing: withoutBatch(try store.heartRates(in: everything))),
     String(describing: withoutBatch(try store.beatIntervals(in: everything))),
     String(describing: withoutBatch(try store.motion(in: everything))),
     String(describing: withoutBatch(try store.aux(in: everything))),
     String(describing: try store.devices().map { advScalars($0.id) + "/" + advScalars($0.name) + "/" + advScalars($0.firmwareVersion) })]
}

/// A store whose every backed-up field is exercised with hostile text, nil/zero values and edits.
private func advHostileStore(time: ManualTimeSource) throws -> FormaStore {
    let store = try makeStore(time: time)
    let origins: [SessionOrigin] = [.manual, .detectedCandidate, .userConfirmed, .userEdited, .imported]
    for (i, text) in advHostileStrings.enumerated() {
        let deviceID = "dev\(i)" + text
        try store.upsertDevice(DeviceRecord(id: deviceID, family: DeviceFamily.allCases[i % DeviceFamily.allCases.count],
                                            name: text, firmwareVersion: i % 2 == 0 ? nil : text,
                                            hardwareRevision: i % 3 == 0 ? text : nil, firstSeen: t0 + Int64(i),
                                            lastConnected: i % 2 == 0 ? nil : t0 + Int64(i)))
        _ = try store.ingest(IngestBatch(
            provenance: provenance(deviceID, note: text),
            heartRates: [hr(t0 + Int64(i), 50 + i, device: deviceID, quality: QualityFlags(rawValue: Int64(i) << 3),
                            deviceTimeRaw: i % 2 == 0 ? nil : Int64(i), clockOffset: i % 3 == 0 ? nil : -Int64(i))],
            beatIntervals: [rr(t0 + Int64(i), 800 + Double(i) / 1_024, recordKey: Int64(i), index: i, device: deviceID)],
            motion: [motionEpoch(t0 + Int64(i), activity: Double(i) * 0.001, device: deviceID)],
            aux: [auxMeasurement(t0 + Int64(i), AuxKind.allCases[i % AuxKind.allCases.count], Double(i), device: deviceID,
                                 validated: i % 2 == 0)],
            cursor: SyncCursor(deviceID: deviceID, adapterID: "a" + text, opaque: Data(text.utf8), newestPersistedRecordTime: t0,
                               lastCompleteSyncAt: nil, updatedAt: t0)))
        let id = try store.insertSession(Session(
            kind: i % 2 == 0 ? .sleep : .workout,
            range: TimeRange(start: t0 + Int64(i) * advHour, end: t0 + Int64(i + 1) * advHour),
            origin: origins[i % origins.count], label: i % 4 == 0 ? nil : text, deviceID: i % 2 == 0 ? deviceID : nil,
            detector: i % 3 == 0 ? "det/" + text : nil,
            confidence: i % 3 == 0 ? Double(i) / Double(advHostileStrings.count) : nil,
            createdAt: t0 - Int64(i), updatedAt: t0 + Int64(i)))
        if i % 2 == 1 {
            var session = try advStoredSession(store, id)
            session.label = text + "!"
            time.advance(byMillis: 1)
            try store.updateSession(session)
        }
        if i % 5 == 4 {
            time.advance(byMillis: 1)
            try store.softDeleteSession(id: id)
        }
        if !text.isEmpty { try store.setSetting(text, forKey: "key " + text) }
    }
    try store.setUserProfile(UserProfile(birthYear: 1975, sex: .female, maxHeartRateOverride: 201))
    return store
}

/// Lines of a file split on LF (the final empty piece after a trailing LF is dropped).
private func advLines(_ url: URL) throws -> [Data] {
    var lines = try Data(contentsOf: url).split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines
}

private func advJSONInt(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let int = value as? Int { return Int64(int) }
    if let int = value as? Int64 { return int }
    return nil
}

/// The first exported line of each record type for a small store holding one record of each type.
private func advTemplateLines() throws -> [String: String] {
    let time = ManualTimeSource(t0)
    let store = try makeStore(time: time)
    try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "N", firstSeen: t0))
    _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 61)],
                                     beatIntervals: [rr(t0, 900, recordKey: 1, index: 0)],
                                     motion: [motionEpoch(t0, activity: 0.25)],
                                     aux: [auxMeasurement(t0, .batteryPercent, 50, validated: true)],
                                     cursor: cursor(newest: t0)))
    let id = try store.insertSession(Session(kind: .sleep, range: TimeRange(start: t0, end: t0 + advHour),
                                             origin: .detectedCandidate, label: "L", confidence: 0.5, createdAt: t0, updatedAt: t0))
    var session = try advStoredSession(store, id)
    session.label = "M"
    try store.updateSession(session)
    try store.setSetting("metric", forKey: "units")
    let directory = try TemporaryDirectory()
    let url = directory.file("template.ndjson")
    try store.exportBackup(to: url)
    var templates: [String: String] = [:]
    for line in try advLines(url).dropFirst() {
        let text = String(decoding: line, as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        if let type = object?["type"] as? String, templates[type] == nil { templates[type] = text }
    }
    return templates
}

@Suite("Adversarial: backup")
struct AdversarialBackupTests {
    @Test func headerAndRecordLinesHaveTheSpecifiedShapeAndMatchTheSummary() throws {
        let time = ManualTimeSource(t0 + 123)
        let source = try advHostileStore(time: time)
        let exportTime = time.now()
        let directory = try TemporaryDirectory()
        let url = directory.file("shape.ndjson")
        let summary = try source.exportBackup(to: url)
        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0A)
        let lines = try advLines(url)
        #expect(lines.count == summary.lineCount)
        #expect(lines.count == 1 + summary.totalRecords, "a record must never span several lines")
        #expect(Int64(data.count) == summary.byteCount)
        let header = try #require(try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        #expect(Set(header.keys) == ["format", "formatVersion", "schemaVersion", "exportedAt", "app"])
        #expect(header["format"] as? String == "forma-backup")
        #expect(advJSONInt(header["formatVersion"]) == 1)
        #expect(advJSONInt(header["schemaVersion"]) == Int64(FormaStore.schemaVersion))
        #expect(advJSONInt(header["exportedAt"]) == exportTime)
        #expect(header["app"] as? String == "Forma")
        let specTypes: Set<String> = ["device", "hr", "rr", "motion", "aux", "session", "correction", "setting", "cursor"]
        var perType: [String: Int] = [:]
        for line in lines.dropFirst() {
            let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
            #expect(Set(object.keys) == ["type", "data"])
            let type = try #require(object["type"] as? String)
            #expect(specTypes.contains(type), "unexpected type \(type)")
            #expect(object["data"] is [String: Any])
            perType[type, default: 0] += 1
        }
        #expect(Set(perType.keys) == specTypes, "a rich store exercises every record type")
        for (type, count) in summary.counts where count > 0 {
            #expect(perType[type.rawValue] == count, "\(type)")
        }
    }

    @Test func hostileRoundTripIntoAFreshStoreIsByteExact() throws {
        let source = try advHostileStore(time: ManualTimeSource(t0))
        let directory = try TemporaryDirectory()
        let url = directory.file("hostile.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore(time: ManualTimeSource(t0 + 999))
        let report = try target.importBackup(from: url)
        #expect(report.invalidLines == 0, "\(report.errors)")
        #expect(try advMeasurementFacts(target) == advMeasurementFacts(source))
        #expect(try target.devices() == source.devices())
        #expect(try target.sessions(includeCandidates: true, includeDeleted: true).map(advSessionFacts).sorted()
                    == source.sessions(includeCandidates: true, includeDeleted: true).map(advSessionFacts).sorted())
        #expect(try advCorrectionFacts(target) == advCorrectionFacts(source))
        for text in advHostileStrings where !text.isEmpty {
            #expect(advScalars(try target.setting(forKey: "key " + text)) == advScalars(text), "\(text.debugDescription)")
        }
        #expect(try target.userProfile() == source.userProfile())
        for (i, text) in advHostileStrings.enumerated() {
            #expect(try target.syncCursor(deviceID: "dev\(i)" + text) == nil)
        }
        #expect(report.cursorsNotApplied.count == advHostileStrings.count)
    }

    @Test func everyRecordLineIsAccountedForExactlyOnceAndReimportAddsNothing() throws {
        let source = try advHostileStore(time: ManualTimeSource(t0))
        let directory = try TemporaryDirectory()
        let url = directory.file("accounting.ndjson")
        let summary = try source.exportBackup(to: url)
        let target = try makeStore()
        let first = try target.importBackup(from: url)
        #expect(first.invalidLines == 0 && first.errors.isEmpty)
        let afterFirst = try target.tableCounts()
        let second = try target.importBackup(from: url)
        for report in [first, second] {
            for type in BackupRecordType.allCases {
                let accounted = (report.inserted[type] ?? 0) + (report.duplicates[type] ?? 0) + (report.notApplied[type] ?? 0)
                #expect(accounted == (summary.counts[type] ?? 0), "\(type)")
            }
        }
        #expect(second.inserted.values.allSatisfy { $0 == 0 })
        var afterSecond = try target.tableCounts()
        afterSecond["ingest_batch"] = afterFirst["ingest_batch"]
        #expect(afterSecond == afterFirst)
    }

    @Test func numbersSurviveTheBackupBitExactly() throws {
        var rng = SplitMix64(seed: 777)
        let source = try makeStore()
        var doubles: [Double] = [.leastNonzeroMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0.1 + 0.2,
                                 1e-300, 1e300, .ulpOfOne, 1.0 / 3, 1e16, 123_456_789.000_001]
        while doubles.count < 300 {
            let candidate = Double(bitPattern: rng.next())
            if candidate.isFinite, candidate != 0 { doubles.append(candidate) }
        }
        let ints: [Int64] = [.min, .min + 1, -1, 0, 1, .max - 1, .max]
        // Fixer note: backup import only accepts timeline values (measurement ts_ms, session bounds,
        // motion epoch length) inside FormaStore.backupTimeWindow / maxBackupEpochMillis, because a
        // file is untrusted input and ranges built from Int64.min/.max overflow downstream (review
        // finding; rejection is covered by HardeningTests.importRejectsTimelineValuesOutsideTheWindow).
        // The extreme integers therefore ride in the fields that do not place a record on the
        // timeline, and the timestamps probe the window's edges instead.
        let window = FormaStore.backupTimeWindow
        let timestamps: [Int64] = [window.start, window.start + 1, 2, t0, t0 + 1, window.end - 2, window.end - 1]
        let samples = ints.enumerated().map { i, value in
            HeartRateSample(deviceID: deviceA, timestamp: timestamps[i], bpm: 30 + i, source: .deviceHistory,
                            deviceTimeRaw: ints[ints.count - 1 - i], receivedAt: value, clockOffsetMillis: ints[(i + 3) % ints.count],
                            quality: QualityFlags(rawValue: value))
        }
        let intervals = doubles.enumerated().map { i, value in
            BeatInterval(deviceID: deviceA, timestamp: t0 + Int64(i), intervalMillis: value, source: .liveVendorStream,
                         recordKey: ints[i % ints.count], indexInRecord: i == 0 ? Int.max : i, receivedAt: .min,
                         timingBasis: i % 2 == 0 ? .reconstructedFromRecordTime : .reconstructedFromReceiveTime,
                         quality: QualityFlags(rawValue: ints[i % ints.count]))
        }
        let epochs = doubles.enumerated().map { i, value in
            MotionEpoch(deviceID: deviceA, timestamp: t0 + Int64(i), epochMillis: FormaStore.maxBackupEpochMillis,
                        activity: value, sampleCount: Int.max, source: .deviceHistory)
        }
        let aux = doubles.enumerated().map { i, value in
            AuxMeasurement(deviceID: deviceA, timestamp: t0 + Int64(i), kind: .skinTemperatureCelsius, value: value,
                           source: .demo, validated: true)
        }
        _ = try source.ingest(IngestBatch(provenance: provenance(), heartRates: samples, beatIntervals: intervals,
                                          motion: epochs, aux: aux))
        for (i, value) in doubles.prefix(50).enumerated() {
            let fraction = abs(value).truncatingRemainder(dividingBy: 1)
            try source.insertSession(Session(kind: .workout, range: TimeRange(start: Int64(i) * 10, end: Int64(i) * 10 + 5),
                                             origin: .detectedCandidate, confidence: fraction, createdAt: .min, updatedAt: .max))
        }
        let directory = try TemporaryDirectory()
        let url = directory.file("numbers.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        let report = try target.importBackup(from: url)
        #expect(report.invalidLines == 0, "\(report.errors)")
        #expect(withoutBatch(try target.heartRates(in: everything)) == withoutBatch(try source.heartRates(in: TimeRange(start: .min, end: .max))))
        #expect(try target.heartRates(in: everything).count == ints.count, "every window edge is importable")
        #expect(try target.tableCounts()["hr_sample"] == ints.count)
        #expect(withoutBatch(try target.beatIntervals(in: everything)).map(\.intervalMillis.bitPattern) == doubles.map(\.bitPattern))
        #expect(withoutBatch(try target.beatIntervals(in: everything)) == withoutBatch(try source.beatIntervals(in: everything)))
        #expect(withoutBatch(try target.motion(in: everything)).map(\.activity.bitPattern) == doubles.map(\.bitPattern))
        #expect(withoutBatch(try target.aux(in: everything)).map(\.value.bitPattern) == doubles.map(\.bitPattern))
        #expect(try target.sessions(includeCandidates: true).map(advSessionFacts).sorted()
                    == source.sessions(includeCandidates: true).map(advSessionFacts).sorted())
    }

    @Test func cursorsInABackupNeverChangeSyncState() throws {
        let source = try makeStore()
        let sourceA = SyncCursor(deviceID: deviceA, adapterID: "whoop5", opaque: Data([0xFF, 0xFF]), newestPersistedRecordTime: .max,
                                 lastCompleteSyncAt: t0 + 999_999, updatedAt: t0 + 999_999)
        let sourceB = cursor(deviceB, newest: t0 + 50_000)
        _ = try source.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)], cursor: sourceA))
        _ = try source.ingest(IngestBatch(provenance: provenance(deviceB), cursor: sourceB))
        let directory = try TemporaryDirectory()
        let url = directory.file("cursors.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        let targetA = cursor(newest: t0 - 5_000, opaque: [1])
        _ = try target.ingest(IngestBatch(provenance: provenance(), cursor: targetA))
        let report = try target.importBackup(from: url)
        #expect(try target.syncCursor(deviceID: deviceA) == targetA)
        #expect(try target.syncCursor(deviceID: deviceB) == nil)
        #expect(Set(report.cursorsNotApplied) == [sourceA, sourceB])
        #expect(report.inserted[.hr] == 1)
        let empty = try makeStore()
        _ = try empty.importBackup(from: url)
        #expect(try empty.syncCursor(deviceID: deviceA) == nil)
        #expect(try empty.syncCursor(deviceID: deviceB) == nil)
    }

    @Test func sessionsAreMatchedOnKindStartEndAndLabelIncludingNilLabels() throws {
        let s = t0
        let e = t0 + advHour
        let source = try makeStore()
        for session in [advSession(.sleep, s, e, origin: .detectedCandidate), advSession(.sleep, s, e, origin: .userConfirmed),
                        advSession(.sleep, s, e, label: "Nap"), advSession(.workout, s, e, origin: .imported, label: "Run"),
                        advSession(.workout, s, e, label: "run"), advSession(.workout, s, e + 1, label: "Run")] {
            try source.insertSession(session)
        }
        let directory = try TemporaryDirectory()
        let url = directory.file("sessions.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        try target.insertSession(advSession(.sleep, s, e))
        try target.insertSession(advSession(.workout, s, e, label: "Run"))
        let report = try target.importBackup(from: url)
        #expect(report.inserted[.session] == 3)
        #expect(report.duplicates[.session] == 3)
        let labels = try target.sessions(includeCandidates: true, includeDeleted: true).map { "\($0.kind.rawValue):\($0.range.end - $0.range.start):\($0.label ?? "nil")" }
        #expect(labels.sorted() == ["sleep:3600000:Nap", "sleep:3600000:nil", "workout:3600000:Run", "workout:3600000:run",
                                    "workout:3600001:Run"])
        let again = try target.importBackup(from: url)
        #expect(again.inserted[.session] ?? 0 == 0)
    }

    @Test func importedRangeCoversEveryNewlyStoredRecord() throws {
        let source = try makeStore()
        let instants = [t0 - 10 * advHour, t0 + 5 * advHour, t0 + 20 * advHour, t0 + 30 * advHour]
        _ = try source.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(instants[0], 60)],
                                          beatIntervals: [rr(instants[1], 900, recordKey: 1, index: 0)],
                                          motion: [motionEpoch(instants[2], activity: 0.1)],
                                          aux: [auxMeasurement(instants[3], .batteryPercent, 50)]))
        let sessionRange = TimeRange(start: t0 - 50 * advHour, end: t0 - 40 * advHour)
        try source.insertSession(Session(kind: .sleep, range: sessionRange, origin: .manual, createdAt: t0, updatedAt: t0))
        let directory = try TemporaryDirectory()
        let url = directory.file("range.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        _ = try target.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(instants[0], 60)]))
        let report = try target.importBackup(from: url)
        let range = try #require(report.importedRange)
        for t in instants.dropFirst() { #expect(range.contains(t), "\(t)") }
        #expect(range.start <= sessionRange.start && range.end >= sessionRange.end)
    }

    @Test func importedMeasurementsKeepTheirSourceAndCarryABackupImportBatch() throws {
        let source = try makeStore()
        _ = try source.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)]))
        _ = try source.ingest(IngestBatch(provenance: provenance(source: .liveVendorStream),
                                          heartRates: [hr(t0, 61, source: .liveVendorStream)]))
        _ = try source.ingest(IngestBatch(provenance: provenance(deviceB, source: .standardHeartRateService),
                                          heartRates: [hr(t0, 62, device: deviceB, source: .standardHeartRateService)]))
        let directory = try TemporaryDirectory()
        let name = "My Backup \u{2013} 2026 \u{2713}.ndjson"
        let url = directory.file(name)
        try source.exportBackup(to: url)
        let target = try makeStore()
        _ = try target.importBackup(from: url)
        let rows = try target.heartRates(in: everything)
        #expect(Set(rows.map(\.source)) == [.liveVendorStream, .deviceHistory, .standardHeartRateService])
        for row in rows {
            let batch = try #require(row.batchID)
            let stored = try #require(try target.provenance(batchID: batch))
            #expect(stored.source == .backupImport)
            #expect(stored.note == name)
        }
        let back = try source.importBackup(from: url)
        #expect((back.inserted[.hr] ?? 0) == 0, "sources are preserved, so restoring into the original store dedups")
    }

    @Test func malformedRecordsAreRejectedOneByOneWithoutDisturbingTheirNeighbours() throws {
        let templates = try advTemplateLines()
        func mutate(_ type: String, _ old: String, _ new: String) throws -> String {
            let line = try #require(templates[type], "no \(type) template")
            try #require(line.contains(old), "\(type) template lacks \(old): \(line)")
            return line.replacingOccurrences(of: old, with: new)
        }
        let hrLine = try #require(templates["hr"])
        let deepArrays = #"{"type":"hr","data":"# + String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000) + "}"
        let deepObjects = #"{"type":"hr","data":{"device_id":"# + String(repeating: #"{"a":"#, count: 60_000) + "1"
            + String(repeating: "}", count: 60_000) + "}}"
        let hugeNumber = "1" + String(repeating: "0", count: 500)
        let bad: [String] = [
            try mutate("hr", #""bpm":61"#, #""bpm":61.5"#),
            try mutate("hr", #""bpm":61"#, #""bpm":"61""#),
            try mutate("hr", #""bpm":61"#, #""bpm":true"#),
            try mutate("hr", #""bpm":61"#, #""bpm":null"#),
            try mutate("hr", #""ts_ms":\#(t0)"#, #""ts_ms":9223372036854775808"#),
            try mutate("hr", #""ts_ms":\#(t0)"#, #""ts_ms":-9223372036854775809"#),
            try mutate("hr", #""source":2"#, #""source":7"#),
            try mutate("hr", #""source":2"#, #""source":null"#),
            try mutate("hr", #"{"type":"hr""#, #"{"type":"HR""#),
            try mutate("hr", #"{"type":"hr""#, #"{"type":null"#),
            hrLine + "x",
            hrLine + hrLine,
            "// " + hrLine,
            #"{"type":"hr","data":null}"#, #"{"type":"hr","data":[]}"#, #"{"type":"hr","data":"x"}"#,
            "{}", "[]", "null", "\"just a string\"", "42",
            try mutate("hr", #""device_id":"band-A""#, "\"device_id\":\"band\u{1}A\""),
            try mutate("rr", #""interval_ms":900.0"#, #""interval_ms":Infinity"#),
            try mutate("rr", #""interval_ms":900.0"#, #""interval_ms":-Infinity"#),
            try mutate("rr", #""interval_ms":900.0"#, #""interval_ms":NaN"#),
            try mutate("rr", #""interval_ms":900.0"#, #""interval_ms":1e400"#),
            try mutate("rr", #""interval_ms":900.0"#, #""interval_ms":-1e400"#),
            try mutate("rr", #""interval_ms":900.0"#, #""interval_ms":"900""#),
            try mutate("rr", #""interval_ms":900.0"#, "\"interval_ms\":\(hugeNumber)"),
            try mutate("rr", #""timing_basis":2"#, #""timing_basis":7"#),
            try mutate("rr", #""idx":0"#, #""idx":-1"#),
            try mutate("motion", #""activity":0.25"#, #""activity":"NaN""#),
            try mutate("aux", #""kind":"batteryPercent""#, #""kind":"glucose""#),
            try mutate("aux", #""validated":true"#, #""validated":1"#),
            try mutate("aux", #""validated":true"#, #""validated":"true""#),
            try mutate("session", #""confidence":0.5"#, #""confidence":1.5"#),
            try mutate("session", #""confidence":0.5"#, #""confidence":-0.1"#),
            try mutate("session", #""kind":"sleep""#, #""kind":"nap""#),
            try mutate("session", #""origin":"detectedCandidate""#, #""origin":"robot""#),
            try mutate("device", #""family":"whoop5""#, #""family":"fitbit""#),
            try mutate("device", #""id":"band-A""#, #""id":"""#),
            deepArrays,
            deepObjects,
        ]
        // Each variant on its own (after the templates it may refer to), so a failure names the variant.
        let preamble = try ["device", "setting", "cursor", "session", "correction"].map { type in
            try #require(templates[type], "no \(type) template")
        }
        let scratch = try TemporaryDirectory()
        for (k, line) in bad.enumerated() {
            let url = scratch.file("variant-\(k).ndjson")
            try advWriteLines([advHeaderLine] + preamble + [line], to: url)
            let report = try makeStore().importBackup(from: url)
            #expect(report.invalidLines == 1, "variant \(k) was accepted: \(String(line.prefix(160)))")
        }
        var lines = [advHeaderLine]
        for type in ["device", "setting", "cursor", "session", "correction", "hr", "rr", "motion", "aux"] {
            lines.append(try #require(templates[type], "no \(type) template"))
        }
        for (k, line) in bad.enumerated() {
            lines.append(line)
            lines.append(advHRLine(t0 + 1_000 + Int64(k)))
        }
        let directory = try TemporaryDirectory()
        let url = directory.file("malformed.ndjson")
        try advWriteLines(lines, to: url)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.invalidLines == bad.count)
        #expect(report.errors.count == min(bad.count, 20))
        #expect(report.errors.allSatisfy { !$0.isEmpty && $0.count < 2_000 })
        #expect(report.inserted[.hr] == 1 + bad.count)
        for type in [BackupRecordType.device, .session, .correction, .rr, .motion, .aux, .setting] {
            #expect(report.inserted[type] == 1, "\(type)")
        }
        #expect(try store.heartRates(in: everything).count == 1 + bad.count)
    }

    @Test func undecodableBytesAreCountedAndNeverCrash() throws {
        let store = try makeStore()
        let validNUL = #"{"type":"hr","data":{"device_id":"\u0000","ts_ms":5,"bpm":60,"source":2,"device_time_raw":null,"received_at":5,"clock_offset_ms":null,"quality":0}}"#
        let hostile: [Data] = [
            Data([0xFF, 0xFE, 0xFD]),
            Data(#"{"type":"hr","data":{"device_id":""#.utf8) + Data([0xC3, 0x28])
                + Data(#"","ts_ms":1,"bpm":60,"source":2,"device_time_raw":null,"received_at":1,"clock_offset_ms":null,"quality":0}}"#.utf8),
            Data(#"{"type":"hr","data":{"device_id":"\uD800","ts_ms":2,"bpm":60,"source":2,"device_time_raw":null,"received_at":2,"clock_offset_ms":null,"quality":0}}"#.utf8),
            Data(#"{"type":"hr","data":{"device_id":"\uDC00\uD800x","ts_ms":3,"bpm":60,"source":2,"device_time_raw":null,"received_at":3,"clock_offset_ms":null,"quality":0}}"#.utf8),
            Data([0x00, 0x00, 0x00]),
            Data([0xEF, 0xBB, 0xBF]) + Data(advHRLine(4).utf8),
            Data(String(repeating: "\u{1F600}", count: 1_000).utf8),
            Data(validNUL.utf8),
        ]
        var data = Data((advHeaderLine + "\n").utf8)
        for line in hostile {
            data += line
            data.append(0x0A)
        }
        let directory = try TemporaryDirectory()
        let url = directory.file("bytes.ndjson")
        try data.write(to: url)
        let report = try store.importBackup(from: url)
        let accounted = report.totalInserted + report.totalDuplicates + report.notApplied.values.reduce(0, +) + report.invalidLines
        #expect(accounted == hostile.count)
        #expect(report.invalidLines >= 3)
        #expect(try store.heartRates(in: everything, deviceID: "\u{0}").count == 1)
    }

    @Test func oversizedLinesAnywhereAreSkippedWithoutLosingTheirNeighbours() throws {
        func padded(_ ts: EpochMillis, _ bytes: Int) -> String {
            String(advHRLine(ts).dropLast(2)) + ",\"pad\":\"" + String(repeating: "p", count: bytes) + "\"}}"
        }
        let lines = [advHeaderLine, advHRLine(t0), padded(t0 + 1, 3_000_000), advHRLine(t0 + 2), padded(t0 + 3, 1_100_000),
                     advHRLine(t0 + 4), padded(t0 + 5, 800_000), advHRLine(t0 + 6), padded(t0 + 7, 2_500_000)]
        let directory = try TemporaryDirectory()
        let url = directory.file("long-lines.ndjson")
        try advWriteLines(lines, to: url, trailingNewline: false)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.invalidLines == 3)
        #expect(report.errors.allSatisfy { $0.count < 2_000 })
        #expect(Set(try store.heartRates(in: everything).map(\.timestamp)) == [t0, t0 + 2, t0 + 4, t0 + 5, t0 + 6])
    }

    @Test(arguments: [
        #"{"format":"forma-backup","formatVersion":2,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"format":"forma-backup","formatVersion":99999999999999999999,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"format":"forma-backup","formatVersion":"1","schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"format":"forma-backup","formatVersion":1.5,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"format":"forma-backup","formatVersion":-1,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"format":"Forma-Backup","formatVersion":1,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"format":"forma-backup ","formatVersion":1,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"formatVersion":1,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#,
        #"{"format":null,"formatVersion":1}"#,
        #"[{"format":"forma-backup","formatVersion":1}]"#,
        #"{"type":"hr","data":{}}"#,
        "",
        "\u{0}",
        String(repeating: " ", count: 2_000_000),
    ])
    func unusableHeadersAreRejectedWithoutWritingAnything(_ header: String) throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("header.ndjson")
        try advWriteLines([header, advHeaderLine, advHRLine(t0)], to: url)
        let store = try makeStore()
        #expect(throws: (any Error).self) { try store.importBackup(from: url) }
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
    }

    @Test func headerOnlyFilesImportNothingAndEmptyFilesAreRejected() throws {
        let directory = try TemporaryDirectory()
        for (name, trailing) in [("a.ndjson", true), ("b.ndjson", false)] {
            let url = directory.file(name)
            try advWriteLines([advHeaderLine], to: url, trailingNewline: trailing)
            let report = try makeStore().importBackup(from: url)
            #expect(report.invalidLines == 0 && report.totalInserted == 0 && report.importedRange == nil)
        }
        let empty = directory.file("empty.ndjson")
        try Data().write(to: empty)
        #expect(throws: (any Error).self) { try makeStore().importBackup(from: empty) }
        #expect(throws: (any Error).self) { try makeStore().importBackup(from: directory.url) }
        #expect(throws: (any Error).self) { try makeStore().importBackup(from: directory.file("missing.ndjson")) }
    }

    @Test func correctionsFollowTheirSessionsAcrossImportChunks() throws {
        let source = try makeStore()
        let n = 2_600
        for i in 0..<n {
            let id = try source.insertSession(advSession(.workout, t0 + Int64(i) * advHour, t0 + Int64(i) * advHour + 1_000,
                                                         label: "s\(i)"))
            var session = try #require(try source.session(id: id))
            session.label = "edited \(i)"
            try source.updateSession(session)
        }
        let directory = try TemporaryDirectory()
        let url = directory.file("chunks.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        let report = try target.importBackup(from: url)
        #expect(report.invalidLines == 0, "\(report.errors.prefix(3))")
        #expect(report.inserted[.session] == n)
        #expect(report.inserted[.correction] == n)
        #expect(try advCorrectionFacts(target) == advCorrectionFacts(source))
    }

    @Test func invalidLineAccountingIsExactAcrossChunks() throws {
        let lines = [advHeaderLine] + (0..<5_000).map { i in i % 2 == 0 ? advHRLine(t0 + Int64(i)) : "garbage \(i)" }
        let directory = try TemporaryDirectory()
        let url = directory.file("noisy.ndjson")
        try advWriteLines(lines, to: url)
        let report = try makeStore().importBackup(from: url)
        #expect(report.invalidLines == 2_500)
        #expect(report.inserted[.hr] == 2_500)
        #expect(report.errors.count == 20)
        for (k, message) in report.errors.enumerated() {
            #expect(message.contains("\(3 + 2 * k)"), "\(message)")
        }
    }

    @Test func tiedTimestampsAcrossPagesAreBackedUpCompletely() throws {
        let source = try makeStore()
        let n = 9_000
        _ = try source.ingest(IngestBatch(provenance: provenance(),
                                          beatIntervals: (0..<n).map { rr(t0, 800, recordKey: t0, index: $0) }))
        let directory = try TemporaryDirectory()
        let url = directory.file("ties.ndjson")
        let summary = try source.exportBackup(to: url)
        #expect(summary.counts[.rr] == n)
        let target = try makeStore()
        #expect(try target.importBackup(from: url).inserted[.rr] == n)
        #expect(try target.beatIntervals(in: everything).map(\.indexInRecord).sorted() == Array(0..<n))
    }

    @Test func restoringAfterDeleteAllDataBringsEverythingBack() throws {
        let store = try advHostileStore(time: ManualTimeSource(t0))
        let measurements = try advMeasurementFacts(store)
        let sessions = try store.sessions(includeCandidates: true, includeDeleted: true).map(advSessionFacts).sorted()
        let corrections = try advCorrectionFacts(store)
        let profile = try store.userProfile()
        let directory = try TemporaryDirectory()
        let url = directory.file("restore.ndjson")
        try store.exportBackup(to: url)
        try store.deleteAllData()
        let report = try store.importBackup(from: url)
        #expect(report.invalidLines == 0)
        #expect(try advMeasurementFacts(store) == measurements)
        #expect(try store.sessions(includeCandidates: true, includeDeleted: true).map(advSessionFacts).sorted() == sessions)
        #expect(try advCorrectionFacts(store) == corrections)
        #expect(try store.userProfile() == profile)
    }
}

// MARK: - Concurrency

@Suite("Adversarial: concurrency")
struct AdversarialConcurrencyTests {
    @Test func identicalDownloadsFromManyThreadsStoreEachRecordOnce() throws {
        let store = try makeStore()
        let tally = AdvLocked<[IngestResult]>([])
        let errors = AdvLocked<[String]>([])
        let batches = 30
        let perBatch = 50
        let threads = 8
        advRunThreads(threads) { worker in
            for step in 0..<batches {
                // Every worker downloads the same history, starting at a different batch.
                let batch = (step + worker * 7) % batches
                let times = (0..<perBatch).map { t0 + Int64(batch * perBatch + $0) * 1_000 }
                do {
                    let result = try store.ingest(IngestBatch(provenance: provenance(), heartRates: times.map { hr($0, 60) },
                                                              beatIntervals: times.map { rr($0, 950, recordKey: $0, index: 0) },
                                                              cursor: cursor(newest: times.last)))
                    tally.mutate { $0.append(result) }
                } catch {
                    errors.mutate { $0.append(String(describing: error)) }
                }
            }
        }
        #expect(errors.value.isEmpty, "\(errors.value.prefix(3))")
        let unique = batches * perBatch * 2
        let results = tally.value
        #expect(results.count == threads * batches)
        #expect(results.reduce(0) { $0 + $1.inserted } == unique)
        #expect(results.reduce(0) { $0 + $1.duplicates } == unique * (threads - 1))
        #expect(Set(results.map(\.batchID)).count == results.count)
        #expect(try store.tableCounts()["hr_sample"] == batches * perBatch)
        let inserting = Set(results.filter { $0.inserted > 0 }.map(\.batchID))
        #expect(try store.heartRates(in: everything).allSatisfy { inserting.contains($0.batchID ?? -1) })
    }

    @Test func twoStoreInstancesOnOneFileIngestConcurrentlyWithoutBusyErrors() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("shared.sqlite")
        let stores = [try FormaStore(path: path, timeSource: ManualTimeSource(t0)),
                      try FormaStore(path: path, timeSource: ManualTimeSource(t0))]
        let errors = AdvLocked<[String]>([])
        advRunThreads(4) { worker in
            let store = stores[worker % stores.count]
            for batch in 0..<25 {
                let base = Int64((worker * 25 + batch) * 20)
                do {
                    _ = try store.ingest(IngestBatch(provenance: provenance(),
                                                     heartRates: (0..<20).map { hr(t0 + (base + Int64($0)) * 1_000, 60) }))
                } catch {
                    errors.mutate { $0.append(String(describing: error)) }
                }
            }
        }
        #expect(errors.value.isEmpty, "\(errors.value.prefix(3))")
        let third = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        #expect(try third.tableCounts()["hr_sample"] == 2_000)
        #expect(try stores[0].heartRates(in: everything).count == 2_000)
    }

    @Test func deleteAllDataRacingIngestLeavesOnlyWholeBatches() throws {
        let store = try makeStore()
        let errors = AdvLocked<[String]>([])
        advRunThreads(5) { worker in
            if worker == 4 {
                for _ in 0..<20 {
                    do { try store.deleteAllData() } catch { errors.mutate { $0.append("delete: \(error)") } }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                return
            }
            for batch in 0..<150 {
                let base = Int64((worker * 150 + batch) * 10)
                let times = (0..<10).map { t0 + (base + Int64($0)) * 1_000 }
                do {
                    _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: times.map { hr($0, 60) },
                                                     beatIntervals: times.map { rr($0, 900, recordKey: $0, index: 0) },
                                                     cursor: cursor(newest: times.last)))
                } catch {
                    errors.mutate { $0.append("ingest: \(error)") }
                }
            }
        }
        #expect(errors.value.isEmpty, "\(errors.value.prefix(3))")
        try store.withConnectionForTesting { db in
            let hrPerBatch = try db.query("SELECT COUNT(*) FROM hr_sample GROUP BY batch_id") { $0.int(0) }
            let rrPerBatch = try db.query("SELECT COUNT(*) FROM beat_interval GROUP BY batch_id") { $0.int(0) }
            #expect(hrPerBatch.allSatisfy { $0 == 10 })
            #expect(rrPerBatch.allSatisfy { $0 == 10 })
            #expect(try db.scalarInt64("SELECT COUNT(*) FROM ingest_batch") == Int64(hrPerBatch.count))
            #expect(try db.scalarInt64("SELECT COUNT(*) FROM hr_sample WHERE batch_id NOT IN (SELECT id FROM ingest_batch)") == 0)
            #expect(try db.scalarInt64("SELECT COUNT(*) FROM beat_interval WHERE batch_id NOT IN (SELECT id FROM ingest_batch)") == 0)
        }
    }

    @Test func concurrentImportsOfOneBackupEqualASingleImport() throws {
        let source = try advHostileStore(time: ManualTimeSource(t0))
        _ = try source.ingest(IngestBatch(provenance: provenance(),
                                          heartRates: (0..<6_000).map { hr(t0 + 10_000_000 + Int64($0) * 1_000, 70) }))
        let directory = try TemporaryDirectory()
        let url = directory.file("shared.ndjson")
        try source.exportBackup(to: url)
        let reference = try makeStore()
        let single = try reference.importBackup(from: url)
        let target = try makeStore()
        let reports = AdvLocked<[ImportReport]>([])
        let errors = AdvLocked<[String]>([])
        advRunThreads(3) { _ in
            do {
                let report = try target.importBackup(from: url)
                reports.mutate { $0.append(report) }
            } catch {
                errors.mutate { $0.append(String(describing: error)) }
            }
        }
        #expect(errors.value.isEmpty, "\(errors.value.prefix(3))")
        #expect(try advMeasurementFacts(target) == advMeasurementFacts(reference))
        #expect(try target.sessions(includeCandidates: true, includeDeleted: true).map(advSessionFacts).sorted()
                    == reference.sessions(includeCandidates: true, includeDeleted: true).map(advSessionFacts).sorted())
        #expect(try advCorrectionFacts(target) == advCorrectionFacts(reference))
        for type in BackupRecordType.allCases {
            let total = reports.value.reduce(0) { $0 + ($1.inserted[type] ?? 0) }
            #expect(total == (single.inserted[type] ?? 0), "\(type)")
        }
    }

    @Test func readersNeverObserveAPartiallyWrittenBatch() throws {
        let store = try makeStore()
        let done = AdvLocked(false)
        let anomalies = AdvLocked<[String]>([])
        advRunThreads(3) { worker in
            if worker == 0 {
                for batch in 0..<100 {
                    let base = Int64(batch * 50)
                    let times = (0..<50).map { t0 + (base + Int64($0)) * 1_000 }
                    do {
                        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: times.map { hr($0, 60) },
                                                         beatIntervals: times.map { rr($0, 900, recordKey: $0, index: 0) }))
                    } catch {
                        anomalies.mutate { $0.append("ingest: \(error)") }
                    }
                }
                done.mutate { $0 = true }
                return
            }
            while !done.value {
                if let counts = try? store.tableCounts() {
                    let heartRates = counts["hr_sample"] ?? -1
                    if heartRates % 50 != 0 || counts["beat_interval"] != heartRates {
                        anomalies.mutate { $0.append("counts \(heartRates)/\(counts["beat_interval"] ?? -1)") }
                    }
                }
                if let rows = try? store.heartRates(in: everything), rows.count % 50 != 0 {
                    anomalies.mutate { $0.append("rows \(rows.count)") }
                }
            }
        }
        #expect(anomalies.value.isEmpty, "\(anomalies.value.prefix(5))")
        #expect(try store.tableCounts()["hr_sample"] == 5_000)
    }

    @Test func exportsRunningAlongsideIngestAreWellFormedAndDuplicateFree() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(),
                                         heartRates: (0..<10_000).map { hr(t0 + Int64($0) * 1_000, 60) }))
        let directory = try TemporaryDirectory()
        let base = directory.url
        let problems = AdvLocked<[String]>([])
        advRunThreads(3) { worker in
            switch worker {
            case 0:
                var rng = SplitMix64(seed: 3)
                for batch in 0..<200 {
                    // New samples land both behind and ahead of the exporters' read positions.
                    let times = (0..<20).map { _ in t0 + Int64.random(in: -5_000...15_000, using: &rng) * 1_000 + Int64(batch % 7) }
                    do {
                        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: times.map { hr($0, 61) }))
                    } catch {
                        problems.mutate { $0.append("ingest: \(error)") }
                    }
                }
            case 1:
                for round in 0..<4 {
                    do {
                        let urls = try store.exportCSV(to: base.appendingPathComponent("csv\(round)", isDirectory: true), range: nil)
                        for url in urls {
                            let text = try String(contentsOf: url, encoding: .utf8)
                            guard let records = parseCSV(text), let header = records.first else {
                                problems.mutate { $0.append("unparseable \(url.lastPathComponent)") }
                                continue
                            }
                            if records.contains(where: { $0.count != header.count }) {
                                problems.mutate { $0.append("ragged \(url.lastPathComponent)") }
                            }
                            if url.lastPathComponent == "hr_samples.csv" {
                                let keyColumns = ["device_id", "source", "ts_epoch_ms"].compactMap { header.firstIndex(of: $0) }
                                let keys = records.dropFirst().map { row in keyColumns.map { row[$0] }.joined(separator: "|") }
                                if keyColumns.count != 3 || Set(keys).count != keys.count {
                                    problems.mutate { $0.append("duplicate CSV rows in round \(round)") }
                                }
                            }
                        }
                    } catch {
                        problems.mutate { $0.append("csv: \(error)") }
                    }
                }
            default:
                for round in 0..<4 {
                    let url = base.appendingPathComponent("backup\(round).ndjson")
                    do {
                        let summary = try store.exportBackup(to: url)
                        let lines = try advLines(url)
                        if lines.count != summary.lineCount { problems.mutate { $0.append("line count \(round)") } }
                        var keys = Set<String>()
                        for line in lines.dropFirst() {
                            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                                  let type = object["type"] as? String, let data = object["data"] as? [String: Any] else {
                                problems.mutate { $0.append("bad backup line in round \(round)") }
                                continue
                            }
                            if type == "hr" {
                                let key = "\(data["device_id"] ?? "")|\(data["source"] ?? "")|\(data["ts_ms"] ?? "")"
                                if !keys.insert(key).inserted { problems.mutate { $0.append("duplicate backup hr in round \(round)") } }
                            }
                        }
                    } catch {
                        problems.mutate { $0.append("backup: \(error)") }
                    }
                }
            }
        }
        #expect(problems.value.isEmpty, "\(problems.value.prefix(5))")
    }

    @Test func concurrentSessionEditsKeepOneCorrectionPerChange() throws {
        let store = try makeStore()
        let ids = try (0..<4).map { i in
            try store.insertSession(advSession(.workout, t0 + Int64(i) * advHour, t0 + Int64(i) * advHour + 1_000))
        }
        let errors = AdvLocked<[String]>([])
        advRunThreads(5) { worker in
            if worker == ids.count {
                for i in 0..<100 {
                    do {
                        try store.putDerived([advDerived("m", t0 + Int64(i), t0 + Int64(i) + 10)])
                        try store.invalidateDerived(overlapping: TimeRange(start: t0, end: t0 + 50))
                    } catch {
                        errors.mutate { $0.append("derived: \(error)") }
                    }
                }
                return
            }
            for edit in 0..<50 {
                do {
                    guard var session = try store.session(id: ids[worker]) else { throw AdvBoom() }
                    session.label = "w\(worker)-\(edit)"
                    try store.updateSession(session)
                } catch {
                    errors.mutate { $0.append("edit: \(error)") }
                }
            }
        }
        #expect(errors.value.isEmpty, "\(errors.value.prefix(3))")
        for (worker, id) in ids.enumerated() {
            let corrections = try store.corrections(sessionID: id)
            #expect(corrections.count == 50)
            #expect(corrections.allSatisfy { $0.field == "label" })
            #expect(try store.session(id: id)?.label == "w\(worker)-49")
        }
        // Windows [t0+i, t0+i+10) for i < 50 overlap the invalidated range; the 50 others survive.
        #expect(try store.derived(metricID: "m", in: TimeRange(start: t0 + 50, end: .max)).count == 50)
        #expect(try store.derived(metricID: "m", in: TimeRange(start: t0, end: t0 + 50)).isEmpty)
    }
}

// MARK: - Odds and ends: statement reuse, file hygiene, extreme clocks

@Suite("Adversarial: robustness")
struct AdversarialRobustnessTests {
    @Test func aStatementStaysReusableAfterAFailedStep() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try db.execute("CREATE TABLE t (x INTEGER UNIQUE NOT NULL)")
        let insert = try db.prepare("INSERT INTO t (x) VALUES (?)")
        var failures = 0
        for x in [1, 2, 2, 3, 1, 4] as [Int64] {
            insert.reset()
            try insert.bind(x, at: 1)
            do { try insert.step() } catch { failures += 1 }
        }
        insert.reset()
        try insert.bind(Int64?.none, at: 1)
        #expect(throws: SQLiteError.self) { try insert.step() }
        insert.reset()
        try insert.bind(Int64(5), at: 1)
        #expect(try insert.step() == .done)
        #expect(failures == 2)
        #expect(try db.query("SELECT x FROM t ORDER BY x") { $0.int64(0) } == [1, 2, 3, 4, 5])
    }

    @Test func exportsLeaveNoTemporaryFilesBehind() throws {
        let store = try makeStore()
        try advPopulateEverything(store)
        let directory = try TemporaryDirectory()
        let csv = directory.url.appendingPathComponent("csv", isDirectory: true)
        for _ in 0..<2 {
            let urls = try store.exportCSV(to: csv, range: nil)
            #expect(Set(urls.map(\.lastPathComponent)) == advCSVFileNames)
            #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: csv.path(percentEncoded: false))) == advCSVFileNames)
        }
        // A directory squatting on one output name makes the export fail without leaving temporary files.
        let blocked = directory.url.appendingPathComponent("blocked", isDirectory: true)
        let squatter = blocked.appendingPathComponent("sessions.csv", isDirectory: true).appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.exportCSV(to: blocked, range: nil) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: blocked.path(percentEncoded: false))
        #expect(Set(leftovers).isSubset(of: advCSVFileNames), "\(leftovers)")
        #expect(FileManager.default.fileExists(atPath: squatter.path(percentEncoded: false)))
        try store.exportBackup(to: directory.file("backup.ndjson"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
        #expect(Set(names) == ["csv", "blocked", "backup.ndjson"])
    }

    @Test(arguments: [Int64.min, Int64.min + 1, -1, Int64.max - 1, Int64.max])
    func extremeClockValuesNeverTrap(now: Int64) throws {
        let store = try makeStore(time: ManualTimeSource(now))
        try store.setRawCaptureEnabled(true)
        try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: now, characteristic: "now", bytes: Data([1]),
                                                parseStatus: "ok"))
        try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: t0, characteristic: "t0", bytes: Data([2]),
                                                parseStatus: "ok"))
        #expect(try store.rawFrames(limit: 10).contains { $0.characteristic == "now" }, "a frame received now is never too old")
        let id = try store.insertSession(advSession(.sleep, t0, t0 + 1))
        var session = try advStoredSession(store, id)
        session.label = "x"
        try store.updateSession(session)
        #expect(try store.corrections(sessionID: id).map(\.createdAt) == [now])
        try store.softDeleteSession(id: id)
        _ = try store.ingest(IngestBatch(provenance: provenance(createdAt: now), heartRates: [hr(t0, 60)]))
        let directory = try TemporaryDirectory()
        let url = directory.file("clock.ndjson")
        try store.exportBackup(to: url)
        let firstLine = try #require(try advLines(url).first)
        let header = try #require(try JSONSerialization.jsonObject(with: firstLine) as? [String: Any])
        #expect(advJSONInt(header["exportedAt"]) == now)
        let report = try makeStore(time: ManualTimeSource(now)).importBackup(from: url)
        #expect(report.invalidLines == 0)
        _ = try store.exportCSV(to: directory.url.appendingPathComponent("csv", isDirectory: true), range: nil)
        try store.deleteAllData()
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
    }

    // IMPLEMENTATION BUG (robustness; the spec does not mention this case explicitly): exportBackup(to:)
    // and exportCSV write through a temporary file that then *replaces* the destination. Given the
    // path of the store's own database file, the live database is unlinked and replaced by the NDJSON
    // text; once its pages have been checkpointed out of the WAL, every measurement is lost (the
    // reopen below fails with "file is not a database"). The store knows its own path and could refuse.
    @Test func exportingABackupOntoTheLiveDatabaseFileNeverDestroysIt() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("live.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60), hr(t0 + 1, 61)]))
            store.close() // checkpoints: the pages now live in the main database file
        }
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            _ = try? store.exportBackup(to: URL(fileURLWithPath: path))
            store.close()
        }
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        #expect(try reopened.heartRates(in: everything).count == 2)
    }
}
