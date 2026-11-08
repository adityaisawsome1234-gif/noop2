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
        #expect(FormaStore.schemaVersion == 1)
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
        let broken = Migration(version: 2, name: "broken", sql: """
            CREATE TABLE extra (x INTEGER);
            INSERT INTO table_that_does_not_exist VALUES (1);
            """)
        #expect(throws: SQLiteError.self) { try Migrations.migrate(db, migrations: Migrations.all + [broken]) }
        #expect(try db.userVersion() == 1)
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'extra'") == 0)
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'hr_sample'") == 1)
    }

    @Test func laterMigrationsApplyOnTopOfExistingData() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try Migrations.migrate(db)
        try db.run("INSERT INTO setting (key, value) VALUES ('k', 'v')")
        let next = Migration(version: 2, name: "add note table", sql: "CREATE TABLE note (body TEXT NOT NULL);")
        try Migrations.migrate(db, migrations: Migrations.all + [next])
        #expect(try db.userVersion() == 2)
        #expect(try db.scalarText("SELECT value FROM setting WHERE key = 'k'") == "v")
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM note") == 0)
        // Running again changes nothing.
        try Migrations.migrate(db, migrations: Migrations.all + [next])
        #expect(try db.userVersion() == 2)
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
}
