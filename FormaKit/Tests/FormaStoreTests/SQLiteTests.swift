import Foundation
import Testing
@testable import FormaStore

@Suite("SQLite wrapper")
struct SQLiteTests {
    private func memory() throws -> SQLiteConnection {
        try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
    }

    @Test func bindsAndReadsEveryType() throws {
        let db = try memory()
        try db.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n INTEGER, c INTEGER, a BLOB, f INTEGER)")
        let insert = try db.prepare("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        try insert.bind(Int64(-42), at: 1)
        try insert.bind(3.25, at: 2)
        try insert.bind("h\u{E9}llo\u{0}w\u{F6}rld \u{1F493}", at: 3)
        try insert.bind(Data([0, 1, 2, 255]), at: 4)
        try insert.bindNull(at: 5)
        try insert.bind(Int(7), at: 6)
        try insert.bind([UInt8]([9, 8]), at: 7)
        try insert.bind(true, at: 8)
        #expect(try insert.step() == .done)
        #expect(insert.parameterCount == 8)

        let select = try db.prepare("SELECT i, r, s, b, n, c, a, f FROM t")
        #expect(try select.step() == .row)
        #expect(select.columnCount == 8)
        #expect(select.columnName(2) == "s")
        #expect(select.int64(0) == -42)
        #expect(select.double(1) == 3.25)
        #expect(select.string(2) == "h\u{E9}llo\u{0}w\u{F6}rld \u{1F493}")
        #expect(select.data(3) == Data([0, 1, 2, 255]))
        #expect(select.isNull(4))
        #expect(select.int64(4) == nil)
        #expect(select.double(4) == nil)
        #expect(select.string(4) == nil)
        #expect(select.data(4) == nil)
        #expect(select.value(4) == .null)
        #expect(select.int(5) == 7)
        #expect(select.bytes(6) == [9, 8])
        #expect(select.bool(7) == true)
        #expect(try select.step() == .done)
    }

    @Test func emptyStringAndEmptyBlobStayDistinctFromNull() throws {
        let db = try memory()
        try db.execute("CREATE TABLE t (s TEXT, b BLOB)")
        try db.run("INSERT INTO t VALUES (?, ?)", ["", Data()])
        let select = try db.prepare("SELECT s, b, typeof(s), typeof(b) FROM t")
        #expect(try select.step() == .row)
        #expect(select.string(0) == "")
        #expect(select.data(1) == Data())
        #expect(select.string(2) == "text")
        #expect(select.string(3) == "blob")
    }

    @Test func gettersNeverInventZeroForUnconvertibleValues() throws {
        let db = try memory()
        try db.execute("CREATE TABLE t (v)")
        try db.run("INSERT INTO t VALUES (?), (?), (?), (?)", ["abc", 1.5, Data([1]), "12"])
        let values = try db.query("SELECT v FROM t ORDER BY rowid") { s in
            [s.int64(0).map(String.init) ?? "nil", s.double(0).map { "\($0)" } ?? "nil"]
        }
        #expect(values == [["nil", "nil"], ["nil", "1.5"], ["nil", "nil"], ["12", "12.0"]])
        #expect(try db.scalarInt64("SELECT 2.0") == 2)
        #expect(try db.scalarInt64("SELECT NULL") == nil)
        #expect(try db.scalarInt64("SELECT 1 WHERE 0") == nil)
    }

    @Test func outOfRangeColumnAndParameterAreHandled() throws {
        let db = try memory()
        let statement = try db.prepare("SELECT ?")
        #expect(throws: SQLiteError.self) { try statement.bind(Int64(1), at: 0) }
        #expect(throws: SQLiteError.self) { try statement.bind(Int64(1), at: 2) }
        try statement.bind(Int64(5), at: 1)
        #expect(try statement.step() == .row)
        #expect(statement.int64(1) == nil)
        #expect(statement.int64(-1) == nil)
        #expect(statement.isNull(9))
    }

    @Test func statementIsReusedInALoop() throws {
        let db = try memory()
        try db.execute("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT)")
        let insert = try db.prepare("INSERT INTO t (k, v) VALUES (?, ?)")
        for k in 1...100 {
            insert.reset()
            try insert.bind(k, "value \(k)")
            try insert.step()
            #expect(db.changes == 1)
            #expect(db.lastInsertRowID == Int64(k))
        }
        #expect(try db.scalarInt64("SELECT COUNT(*) FROM t") == 100)
        #expect(try db.scalarText("SELECT v FROM t WHERE k = 42") == "value 42")
    }

    @Test func resetClearsBindingsToNull() throws {
        let db = try memory()
        let statement = try db.prepare("SELECT ?")
        try statement.bind("x", at: 1)
        #expect(try statement.step() == .row)
        #expect(statement.string(0) == "x")
        statement.reset()
        #expect(try statement.step() == .row)
        #expect(statement.isNull(0))
    }

    @Test func transactionCommitsOrRollsBack() throws {
        let db = try memory()
        try db.execute("CREATE TABLE t (v INTEGER)")
        let committed = try db.transaction { () -> Int in
            try db.run("INSERT INTO t VALUES (1)")
            return 1
        }
        #expect(committed == 1)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (2)")
                throw Boom()
            }
        }
        #expect(!db.isInTransaction)
        #expect(try db.query("SELECT v FROM t") { $0.int64(0) } == [1])
    }

    @Test func nestedTransactionRollsBackOnlyTheInnerPart() throws {
        let db = try memory()
        try db.execute("CREATE TABLE t (v INTEGER)")
        struct Boom: Error {}
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            #expect(db.isInTransaction)
            #expect(throws: Boom.self) {
                try db.transaction {
                    try db.run("INSERT INTO t VALUES (2)")
                    throw Boom()
                }
            }
            _ = try db.transaction { try db.run("INSERT INTO t VALUES (3)") }
        }
        #expect(try db.query("SELECT v FROM t ORDER BY v") { $0.int64(0) } == [1, 3])
    }

    @Test func errorsCarryCodeMessageAndSQL() throws {
        let db = try memory()
        try db.execute("CREATE TABLE t (k INTEGER PRIMARY KEY)")
        try db.run("INSERT INTO t VALUES (1)")
        let constraint = #expect(throws: SQLiteError.self) { try db.run("INSERT INTO t VALUES (1)") }
        #expect(constraint?.code == 19)               // SQLITE_CONSTRAINT
        #expect(constraint?.extendedCode == 1_555)    // SQLITE_CONSTRAINT_PRIMARYKEY
        #expect(constraint?.sql == "INSERT INTO t VALUES (1)")
        #expect(constraint?.message.contains("UNIQUE") == true)

        let syntax = #expect(throws: SQLiteError.self) { _ = try db.prepare("SELEC 1") }
        #expect(syntax?.code == 1)                    // SQLITE_ERROR
        #expect(syntax?.sql == "SELEC 1")
        let empty = #expect(throws: SQLiteError.self) { _ = try db.prepare("  -- nothing") }
        #expect(empty?.code == 21)                    // SQLITE_MISUSE
    }

    @Test func closedConnectionThrowsInsteadOfCrashing() throws {
        let db = try memory()
        let statement = try db.prepare("SELECT 1")
        db.close()
        db.close()
        #expect(!db.isOpen)
        #expect(throws: SQLiteError.self) { try db.execute("SELECT 1") }
        #expect(throws: SQLiteError.self) { _ = try db.prepare("SELECT 1") }
        #expect(throws: SQLiteError.self) { try statement.step() }
        #expect(statement.int64(0) == nil)
        #expect(db.changes == 0)
    }

    @Test func fileDatabaseIsConfiguredAtOpen() throws {
        let directory = try TemporaryDirectory()
        let db = try SQLiteConnection(path: directory.path("pragmas.sqlite"))
        #expect(try db.scalarText("PRAGMA journal_mode") == "wal")
        #expect(try db.scalarInt64("PRAGMA foreign_keys") == 1)
        #expect(try db.scalarInt64("PRAGMA busy_timeout") == 5_000)
        #expect(try db.scalarInt64("PRAGMA synchronous") == 1)  // NORMAL
        #expect(!db.isInMemory)
    }

    @Test func memoryDatabaseIgnoresWALButKeepsOtherPragmas() throws {
        let db = try memory()
        #expect(db.isInMemory)
        #expect(try db.scalarText("PRAGMA journal_mode") == "memory")
        #expect(try db.scalarInt64("PRAGMA foreign_keys") == 1)
    }

    @Test func openingAnUnreachablePathThrows() throws {
        let directory = try TemporaryDirectory()
        // A regular file used as a directory component cannot be opened.
        #expect(FileManager.default.createFile(atPath: directory.path("file"), contents: Data([1])))
        #expect(throws: SQLiteError.self) { _ = try SQLiteConnection(path: directory.path("file") + "/db.sqlite") }
    }

    @Test func headerPragmaHelpers() throws {
        let db = try memory()
        #expect(try db.userVersion() == 0)
        try db.setUserVersion(7)
        #expect(try db.userVersion() == 7)
        #expect(try db.applicationID() == 0)
    }

    @Test func errorDescriptionIsReadable() {
        let error = SQLiteError(code: 2_067, message: "UNIQUE constraint failed: t.k", sql: "INSERT")
        #expect(error.code == 19)
        #expect(error.extendedCode == 2_067)
        #expect(error.description == "SQLite error 19/2067: UNIQUE constraint failed: t.k [INSERT]")
    }
}
