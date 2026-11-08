import Foundation
import Testing
import FormaCore
@testable import FormaStore

@Suite("Migrations")
struct MigrationTests {
    @Test func freshStoreHasEveryTableAtTheLatestVersion() throws {
        let store = try makeStore()
        let counts = try store.tableCounts()
        #expect(Set(counts.keys) == Set(Schema.allTables))
        #expect(counts.values.allSatisfy { $0 == 0 })
        let (version, owner) = try store.withConnectionForTesting { db in (try db.userVersion(), try db.applicationID()) }
        #expect(version == FormaStore.schemaVersion)
        #expect(owner == Migrations.applicationID)
        #expect(FormaStore.schemaVersion == 2)
    }

    @Test func schemaHasTheIndexesQueriesRelyOn() throws {
        let store = try makeStore()
        let indexes = try store.withConnectionForTesting { db in
            Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'") {
                $0.string(0)
            })
        }
        for table in Schema.measurementTables {
            #expect(indexes.contains("idx_\(table)_ts"))
            #expect(indexes.contains("idx_\(table)_device_ts"))
        }
        #expect(indexes.isSuperset(of: ["idx_session_kind_start", "idx_raw_frame_received_at", "idx_connection_event_ts"]))
    }

    @Test func versionsAreContiguousFromOne() {
        #expect(Migrations.all.map(\.version) == Array(1...Migrations.all.count))
        #expect(Migrations.latestVersion == Migrations.all.count)
    }

    @Test func reopeningAnUpToDateFileIsANoOp() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("forma.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 61)]))
        }
        for _ in 0..<2 {
            let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            #expect(try reopened.withConnectionForTesting { try $0.userVersion() } == FormaStore.schemaVersion)
            #expect(try reopened.heartRates(in: everything).map(\.bpm) == [61])
        }
    }

    @Test func newerSchemaIsRefusedAndNeverDowngraded() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("future.sqlite")
        do { _ = try FormaStore(path: path) }
        let future = FormaStore.schemaVersion + 5
        do {
            let raw = try SQLiteConnection(path: path)
            try raw.setUserVersion(future)
        }
        #expect(throws: StoreError.schemaTooNew(found: future, supported: FormaStore.schemaVersion)) {
            _ = try FormaStore(path: path)
        }
        let raw = try SQLiteConnection(path: path)
        #expect(try raw.userVersion() == future)
    }

    @Test func plainSQLiteFileWithNewerVersionIsRefused() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("plain.sqlite")
        do { try SQLiteConnection(path: path).setUserVersion(99) }
        #expect(throws: StoreError.schemaTooNew(found: 99, supported: FormaStore.schemaVersion)) {
            _ = try FormaStore(path: path)
        }
    }

    @Test func anotherApplicationsDatabaseIsRefused() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("other.sqlite")
        do { try SQLiteConnection(path: path).execute("PRAGMA application_id = 42") }
        #expect(throws: StoreError.notAFormaDatabase(applicationID: 42)) { _ = try FormaStore(path: path) }
    }

    @Test func failingMigrationIsRolledBack() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        let broken = Migration(version: Migrations.latestVersion + 1, name: "broken", sql: """
            CREATE TABLE extra (x INTEGER);
            INSERT INTO table_that_does_not_exist VALUES (1);
            """)
        #expect(throws: SQLiteError.self) { try Migrations.migrate(db, migrations: Migrations.all + [broken]) }
        #expect(try db.userVersion() == Migrations.latestVersion)
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'extra'") == 0)
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'hr_sample'") == 1)
    }

    @Test func laterMigrationsApplyOnTopOfExistingData() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try Migrations.migrate(db)
        try db.run("INSERT INTO setting (key, value) VALUES ('k', 'v')")
        let next = Migration(version: Migrations.latestVersion + 1, name: "add note table", sql: "CREATE TABLE note (body TEXT NOT NULL);")
        try Migrations.migrate(db, migrations: Migrations.all + [next])
        #expect(try db.userVersion() == Migrations.latestVersion + 1)
        #expect(try db.scalarText("SELECT value FROM setting WHERE key = 'k'") == "v")
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM note") == 0)
        // Running again changes nothing.
        try Migrations.migrate(db, migrations: Migrations.all + [next])
        #expect(try db.userVersion() == Migrations.latestVersion + 1)
    }

    @Test func emptyPathIsRejected() {
        #expect(throws: StoreError.invalidArgument("database path is empty")) { _ = try FormaStore(path: "") }
    }

    @Test func missingParentDirectoriesAreCreated() throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appendingPathComponent("a/b/forma.sqlite").path(percentEncoded: false)
        let store = try FormaStore(path: path)
        #expect(store.path == path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func schemaV2KeysBandRecordsByTheirRawDeviceTimeAndDropsEarlierDuplicates() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        // A v1 database in which one band record was stored twice (two downloads, different clock offsets).
        try Migrations.migrate(db, migrations: [Migrations.all[0]])
        for (ts, offset) in [(1_770_000_000_000, 0), (1_770_000_010_000, 10_000)] as [(Int64, Int64)] {
            try db.run("""
                INSERT INTO hr_sample (device_id, ts_ms, bpm, source, device_time_raw, received_at, clock_offset_ms, quality)
                VALUES ('band', \(ts), 60, \(MeasurementSource.deviceHistory.rawValue), 1770000000, \(ts), \(offset), 64)
                """)
        }
        try db.run("""
            INSERT INTO hr_sample (device_id, ts_ms, bpm, source, received_at, quality)
            VALUES ('band', 1770000000500, 61, \(MeasurementSource.standardHeartRateService.rawValue), 1770000000500, 1)
            """)
        try Migrations.migrate(db)
        #expect(try db.userVersion() == 2)
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM hr_sample WHERE device_time_raw = 1770000000") == 1)
        #expect(try db.scalarInt64("SELECT ts_ms FROM hr_sample WHERE device_time_raw = 1770000000") == 1_770_000_000_000,
                "the first stored copy is kept")
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM hr_sample WHERE device_time_raw IS NULL") == 1, "live rows untouched")
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM pragma_table_info('motion_epoch') WHERE name = 'device_time_raw'") == 1)
    }

    @Test func reDownloadedBandRecordsWithANewClockOffsetAreDuplicates() throws {
        let store = try makeStore()
        let t: Int64 = 1_770_000_000_000
        func batch(offset: Int64) -> IngestBatch {
            let p = Provenance(deviceID: "band", adapterID: "a", parserVersion: "p", firmwareVersion: nil, source: .deviceHistory,
                               syncRunID: nil, createdAt: t, note: "history")
            let hr = HeartRateSample(deviceID: "band", timestamp: t + offset, bpm: 60, source: .deviceHistory, deviceTimeRaw: t / 1_000,
                                     receivedAt: t, clockOffsetMillis: offset == 0 ? nil : offset, quality: [.unvalidatedField])
            let motion = MotionEpoch(deviceID: "band", timestamp: t + offset, epochMillis: 2_000, activity: 3.5, sampleCount: 100,
                                     source: .deviceHistory, quality: [.unvalidatedField], deviceTimeRaw: t / 1_000)
            return IngestBatch(provenance: p, heartRates: [hr], motion: [motion])
        }
        let first = try store.ingest(batch(offset: 0))
        let second = try store.ingest(batch(offset: 10_400))
        #expect(first.inserted == 2 && first.duplicates == 0)
        #expect(second.inserted == 0 && second.duplicates == 2, "same band records, different offset: duplicates")
        #expect(try store.heartRates(in: TimeRange(start: 0, end: .max), deviceID: "band").count == 1)
        let motion = try store.motion(in: TimeRange(start: 0, end: .max), deviceID: "band")
        #expect(motion.count == 1 && motion.first?.deviceTimeRaw == t / 1_000)
    }
}
