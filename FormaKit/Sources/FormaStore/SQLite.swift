import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// MARK: - SQLITE_TRANSIENT

/// `SQLITE_TRANSIENT`, rebuilt for Swift.
///
/// The C header defines it as `((sqlite3_destructor_type)-1)`, a macro Swift cannot import.
/// Passed to `sqlite3_bind_text*` / `sqlite3_bind_blob*` it makes SQLite copy the bytes before the
/// call returns. That is mandatory here: Swift only guarantees a `String`'s or `Data`'s storage for
/// the duration of the call, so `SQLITE_STATIC` (a nil destructor) would leave SQLite reading freed
/// memory. `Int` is pointer-sized on every Apple and Linux target, so the all-ones bit pattern of
/// the C cast is reproduced exactly. (Computed, so it is not global mutable state.)
var SQLITE_TRANSIENT: sqlite3_destructor_type {
    unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)
}

// MARK: - Errors

/// A failed SQLite call.
public struct SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Primary result code (for example `SQLITE_CONSTRAINT` = 19, `SQLITE_BUSY` = 5).
    public let code: Int32
    /// Extended result code (for example `SQLITE_CONSTRAINT_UNIQUE` = 2067); equals `code` when unknown.
    public let extendedCode: Int32
    /// SQLite's message for the failing call.
    public let message: String
    /// The statement that failed, if any. It contains `?` placeholders only, never bound values.
    public let sql: String?

    public init(code: Int32, extendedCode: Int32? = nil, message: String, sql: String? = nil) {
        self.code = code & 0xFF
        self.extendedCode = extendedCode ?? code
        self.message = message
        self.sql = sql
    }

    public var description: String {
        var text = "SQLite error \(code)"
        if extendedCode != code { text += "/\(extendedCode)" }
        text += ": \(message)"
        if let sql { text += " [\(sql)]" }
        return text
    }

    /// Another connection holds a conflicting lock (`SQLITE_BUSY` or `SQLITE_LOCKED`); retrying later can succeed.
    public var isBusy: Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }
    /// The disk (or the database's size limit) is full (`SQLITE_FULL`).
    public var isDiskFull: Bool { code == SQLITE_FULL }
    /// The file is damaged or is not a database at all (`SQLITE_CORRUPT` or `SQLITE_NOTADB`).
    public var isCorrupt: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

/// `localizedDescription` (and SwiftUI's error alerts) show `description`.
extension SQLiteError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - Values

/// A value in one of SQLite's five storage classes.
public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// A type that can be bound as a statement parameter. `Optional.none` binds SQL `NULL`.
public protocol SQLiteValueConvertible {
    var sqliteValue: SQLiteValue { get }
}

extension SQLiteValue: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { self }
}

extension Int64: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .integer(self) }
}

extension Int: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .integer(Int64(self)) }
}

extension Int32: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .integer(Int64(self)) }
}

/// Stored as INTEGER 1 / 0.
extension Bool: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .integer(self ? 1 : 0) }
}

/// Note: SQLite stores NaN as NULL. Callers must reject non-finite values before binding.
extension Double: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .real(self) }
}

extension String: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .text(self) }
}

extension Data: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .blob(self) }
}

extension Array: SQLiteValueConvertible where Element == UInt8 {
    public var sqliteValue: SQLiteValue { .blob(Data(self)) }
}

extension Optional: SQLiteValueConvertible where Wrapped: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { self?.sqliteValue ?? .null }
}

/// Outcome of `SQLiteStatement.step()`.
public enum SQLiteStepResult: Sendable, Equatable {
    /// A result row is available through the column getters.
    case row
    /// The statement ran to completion.
    case done
}

// MARK: - Connection

/// One SQLite database connection.
///
/// Opened with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX` and configured
/// with `journal_mode=WAL` (impossible for in-memory databases, where the failure is ignored),
/// `foreign_keys=ON`, `busy_timeout=5000` ms and `synchronous=NORMAL`. Closed in `deinit`.
///
/// Thread safety: FULLMUTEX keeps SQLite's own state consistent, but sequences such as "step, read
/// columns, read `changes`" are not atomic. Use a connection and its statements from one thread at
/// a time, or guard them with a lock (as `FormaStore` does). Not `Sendable` for that reason.
public final class SQLiteConnection {
    /// Path that opens a private, temporary in-memory database.
    public static let inMemoryPath = ":memory:"
    /// How long a call waits for a lock held by another connection before failing with `SQLITE_BUSY`.
    public static let busyTimeoutMillis: Int32 = 5_000

    /// The path the connection was opened with.
    public let path: String
    private var db: OpaquePointer?
    private var savepointSerial = 0

    /// Opens (creating if needed) the database at `path`, fully configured (WAL included); pass
    /// `SQLiteConnection.inMemoryPath` for an in-memory database.
    public convenience init(path: String) throws {
        try self.init(path: path, enableWAL: true)
    }

    /// Opens the database. With `enableWAL: false` every pragma except `journal_mode` is applied, so
    /// the file's header can be inspected before anything rewrites it; call `enableWAL()` afterwards.
    init(path: String, enableWAL: Bool) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { Self.message(of: $0) } ?? "unable to allocate a database connection"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        db = handle
        do {
            try configure()
            if enableWAL { try self.enableWAL() }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    /// True until `close()` is called.
    public var isOpen: Bool { db != nil }

    /// True for `:memory:` and the empty path (a private temporary database), which cannot use WAL.
    /// (URI filenames such as `file::memory:` are not special: the connection is not opened with
    /// `SQLITE_OPEN_URI`, so they name ordinary files.)
    public var isInMemory: Bool {
        path == Self.inMemoryPath || path.isEmpty
    }

    /// Closes the connection. Idempotent. Statements still alive are finalized when released;
    /// using them afterwards throws instead of touching freed memory.
    public func close() {
        guard let handle = db else { return }
        db = nil
        sqlite3_close_v2(handle)
    }

    /// Connection-level settings that never modify the file.
    private func configure() throws {
        let handle = try openHandle(nil)
        sqlite3_busy_timeout(handle, Self.busyTimeoutMillis)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
    }

    /// Switches the database to `journal_mode=WAL` (persistent: it rewrites the file header). A
    /// failure is ignored for in-memory databases, which cannot use WAL.
    func enableWAL() throws {
        let walSQL = "PRAGMA journal_mode = WAL"
        if isInMemory {
            _ = try? scalarText(walSQL)
            return
        }
        let mode = try scalarText(walSQL)
        guard mode?.lowercased() == "wal" else {
            throw SQLiteError(code: SQLITE_ERROR, message: "could not enable WAL (journal_mode is \(mode ?? "unknown"))",
                              sql: walSQL)
        }
    }

    // MARK: Statements

    /// Runs one or more parameterless SQL statements (DDL, PRAGMAs, BEGIN/COMMIT). Result rows are discarded.
    public func execute(_ sql: String) throws {
        let handle = try openHandle(sql)
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? Self.message(of: handle)
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, extendedCode: sqlite3_extended_errcode(handle), message: message, sql: sql)
        }
    }

    /// Compiles a single SQL statement. Reuse the result in loops: `reset()`, bind, `step()`.
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        let handle = try openHandle(sql)
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw error(rc, sql: sql)
        }
        guard let statement else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "SQL text contains no statement", sql: sql)
        }
        return SQLiteStatement(handle: statement, connection: self, sql: sql)
    }

    /// Prepares `sql`, binds `values` to parameters 1...n, steps to completion and returns the rows
    /// this statement inserted, updated or deleted (0 for statements that change no rows, such as
    /// SELECT, DDL and most PRAGMAs, and for an INSERT skipped by `ON CONFLICT DO NOTHING`).
    @discardableResult
    public func run(_ sql: String, _ values: [any SQLiteValueConvertible] = []) throws -> Int {
        let handle = try openHandle(sql)
        let changesBefore = sqlite3_total_changes(handle)
        let statement = try prepare(sql)
        try statement.bind(values: values)
        while try statement.step() == .row {}
        // `sqlite3_changes` still reports the previous INSERT/UPDATE/DELETE after a statement that
        // changed nothing, so only trust it when this statement moved the running total.
        return sqlite3_total_changes(handle) == changesBefore ? 0 : changes
    }

    /// Runs a query and decodes every row; rows for which `decode` returns nil are skipped.
    public func query<T>(_ sql: String, _ values: [any SQLiteValueConvertible] = [],
                         _ decode: (SQLiteStatement) throws -> T?) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values: values)
        var rows: [T] = []
        while try statement.step() == .row {
            if let row = try decode(statement) { rows.append(row) }
        }
        return rows
    }

    /// First column of the first row as an integer; nil when there is no row or the value is NULL.
    public func scalarInt64(_ sql: String, _ values: [any SQLiteValueConvertible] = []) throws -> Int64? {
        let statement = try prepare(sql)
        try statement.bind(values: values)
        return try statement.step() == .row ? statement.int64(0) : nil
    }

    /// First column of the first row as text; nil when there is no row or the value is NULL.
    public func scalarText(_ sql: String, _ values: [any SQLiteValueConvertible] = []) throws -> String? {
        let statement = try prepare(sql)
        try statement.bind(values: values)
        return try statement.step() == .row ? statement.string(0) : nil
    }

    // MARK: Transactions

    /// Runs `body` atomically: `BEGIN IMMEDIATE` … `COMMIT`, or `ROLLBACK` if `body` (or the commit)
    /// throws, after which the error is rethrown. IMMEDIATE takes the write lock up front, so a
    /// transaction never fails half-way with `SQLITE_BUSY` on its first write. When a transaction is
    /// already open, `body` runs inside a SAVEPOINT instead, so an inner failure undoes only the
    /// inner work.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let handle = try openHandle("BEGIN IMMEDIATE")
        if sqlite3_get_autocommit(handle) == 0 {
            savepointSerial += 1
            let name = "forma_savepoint_\(savepointSerial)"
            try execute("SAVEPOINT \(name)")
            do {
                let result = try body()
                try execute("RELEASE SAVEPOINT \(name)")
                return result
            } catch {
                try? execute("ROLLBACK TO SAVEPOINT \(name)")
                try? execute("RELEASE SAVEPOINT \(name)")
                throw error
            }
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            if let open = db, sqlite3_get_autocommit(open) == 0 {
                try? execute("ROLLBACK")
            }
            throw error
        }
    }

    /// True while an explicit transaction is open.
    public var isInTransaction: Bool {
        guard let db else { return false }
        return sqlite3_get_autocommit(db) == 0
    }

    /// Rows changed by the most recently completed INSERT, UPDATE or DELETE (0 for an INSERT that
    /// was skipped by `ON CONFLICT DO NOTHING`).
    public var changes: Int {
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// Rowid of the most recent successful INSERT on this connection.
    public var lastInsertRowID: Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: Header pragmas

    /// `PRAGMA user_version`, used as the schema version.
    public func userVersion() throws -> Int {
        Int(try scalarInt64("PRAGMA user_version") ?? 0)
    }

    /// Writes `PRAGMA user_version` (clamped to Int32). Transactional when called inside a transaction.
    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(Int32(clamping: version))")
    }

    /// `PRAGMA application_id`, which identifies the application that owns the file.
    public func applicationID() throws -> Int32 {
        Int32(truncatingIfNeeded: try scalarInt64("PRAGMA application_id") ?? 0)
    }

    // MARK: Internals

    private func openHandle(_ sql: String?) throws -> OpaquePointer {
        guard let db else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "database connection is closed", sql: sql)
        }
        return db
    }

    func error(_ rc: Int32, sql: String?) -> SQLiteError {
        guard let db else {
            return SQLiteError(code: rc, message: "database connection is closed", sql: sql)
        }
        return SQLiteError(code: rc, extendedCode: sqlite3_extended_errcode(db), message: Self.message(of: db), sql: sql)
    }

    private static func message(of handle: OpaquePointer) -> String {
        sqlite3_errmsg(handle).map { String(cString: $0) } ?? "unknown SQLite error"
    }
}

// MARK: - Statement

/// A compiled statement. Bind parameters (1-based), `step()`, read columns (0-based), `reset()`
/// and repeat. Finalized in `deinit`. Keeps its connection alive. Same threading rules as
/// `SQLiteConnection`.
public final class SQLiteStatement {
    /// The statement's SQL text.
    public let sql: String
    private var handle: OpaquePointer?
    private let connection: SQLiteConnection

    init(handle: OpaquePointer, connection: SQLiteConnection, sql: String) {
        self.handle = handle
        self.connection = connection
        self.sql = sql
    }

    deinit { finalize() }

    /// Releases the compiled statement now. Later use throws.
    public func finalize() {
        guard let statement = handle else { return }
        handle = nil
        sqlite3_finalize(statement)
    }

    /// Number of `?` parameters.
    public var parameterCount: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_bind_parameter_count(handle))
    }

    /// Number of result columns.
    public var columnCount: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_column_count(handle))
    }

    /// Name of result column `column` (0-based).
    public func columnName(_ column: Int) -> String? {
        guard let statement = columnHandle(column), let name = sqlite3_column_name(statement, Int32(column)) else {
            return nil
        }
        return String(cString: name)
    }

    // MARK: Binding (parameter indexes are 1-based)

    /// Binds `value` to parameter `index`. Text and blobs are copied (`SQLITE_TRANSIENT`); an empty
    /// string or empty blob stays empty and is never turned into NULL.
    public func bind(_ value: SQLiteValue, at index: Int) throws {
        let statement = try liveHandle()
        guard let position = Int32(exactly: index), position >= 1 else {
            throw SQLiteError(code: SQLITE_RANGE, message: "parameter index \(index) is out of range", sql: sql)
        }
        let rc: Int32
        switch value {
        case .null: rc = sqlite3_bind_null(statement, position)
        case .integer(let number): rc = sqlite3_bind_int64(statement, position, number)
        case .real(let number): rc = sqlite3_bind_double(statement, position, number)
        case .text(let text): rc = Self.bindText(statement, position, text)
        case .blob(let bytes): rc = Self.bindBlob(statement, position, bytes)
        }
        guard rc == SQLITE_OK else { throw connection.error(rc, sql: sql) }
    }

    // Typed conveniences for `bind(_:at:)`; a typed nil (`Int64?.none`, an optional variable) binds
    // NULL. `Bool` binds 1/0, `[UInt8]` a blob. A bare `nil` literal matches every overload, so bind
    // an untyped NULL with `bindNull(at:)` or `bind(SQLiteValue.null, at:)`.
    public func bind(_ value: Int64?, at index: Int) throws { try bind(value.sqliteValue, at: index) }
    public func bind(_ value: Int?, at index: Int) throws { try bind(value.sqliteValue, at: index) }
    public func bind(_ value: Bool?, at index: Int) throws { try bind(value.sqliteValue, at: index) }
    public func bind(_ value: Double?, at index: Int) throws { try bind(value.sqliteValue, at: index) }
    public func bind(_ value: String?, at index: Int) throws { try bind(value.sqliteValue, at: index) }
    public func bind(_ value: Data?, at index: Int) throws { try bind(value.sqliteValue, at: index) }
    public func bind(_ value: [UInt8]?, at index: Int) throws { try bind(value.sqliteValue, at: index) }
    public func bindNull(at index: Int) throws { try bind(SQLiteValue.null, at: index) }

    /// Binds `values` to parameters 1...n in order.
    public func bind(values: [any SQLiteValueConvertible]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value.sqliteValue, at: offset + 1)
        }
    }

    /// Variadic form of `bind(values:)`.
    public func bind(_ values: any SQLiteValueConvertible...) throws {
        try bind(values: values)
    }

    private static func bindText(_ statement: OpaquePointer, _ position: Int32, _ text: String) -> Int32 {
        var text = text
        return text.withUTF8 { utf8 -> Int32 in
            guard let base = utf8.baseAddress, !utf8.isEmpty else {
                // A nil pointer would bind NULL; an empty string must stay an empty string.
                return sqlite3_bind_text(statement, position, "", 0, SQLITE_TRANSIENT)
            }
            return base.withMemoryRebound(to: CChar.self, capacity: utf8.count) { chars in
                sqlite3_bind_text64(statement, position, chars, sqlite3_uint64(utf8.count),
                                    SQLITE_TRANSIENT, UInt8(SQLITE_UTF8))
            }
        }
    }

    private static func bindBlob(_ statement: OpaquePointer, _ position: Int32, _ bytes: Data) -> Int32 {
        guard !bytes.isEmpty else {
            // A nil pointer would bind NULL; an empty blob must stay an empty blob.
            return sqlite3_bind_zeroblob(statement, position, 0)
        }
        return bytes.withUnsafeBytes { raw -> Int32 in
            sqlite3_bind_blob64(statement, position, raw.baseAddress, sqlite3_uint64(raw.count), SQLITE_TRANSIENT)
        }
    }

    // MARK: Execution

    /// Advances to the next row (`.row`) or to completion (`.done`). Throws on any other result.
    @discardableResult
    public func step() throws -> SQLiteStepResult {
        let statement = try liveHandle()
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default: throw connection.error(rc, sql: sql)
        }
    }

    /// Rewinds the statement so it can be stepped again; by default also clears bindings to NULL.
    public func reset(clearBindings: Bool = true) {
        guard let statement = handle, connection.isOpen else { return }
        sqlite3_reset(statement)
        if clearBindings { sqlite3_clear_bindings(statement) }
    }

    // MARK: Columns (indexes are 0-based). Every getter returns nil for SQL NULL, never 0 or "".

    /// True when the column is SQL NULL (or the index is invalid).
    public func isNull(_ column: Int) -> Bool {
        guard let statement = columnHandle(column) else { return true }
        return sqlite3_column_type(statement, Int32(column)) == SQLITE_NULL
    }

    /// The column in its stored storage class.
    public func value(_ column: Int) -> SQLiteValue {
        guard let statement = columnHandle(column) else { return .null }
        let position = Int32(column)
        switch sqlite3_column_type(statement, position) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, position))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, position))
        case SQLITE_TEXT: return string(column).map(SQLiteValue.text) ?? .null
        case SQLITE_BLOB: return data(column).map(SQLiteValue.blob) ?? .null
        default: return .null
        }
    }

    /// INTEGER as-is; REAL only when integral; TEXT only when it parses exactly; otherwise nil.
    /// (SQLite's own conversion would turn unconvertible values into 0, which would fabricate data.)
    public func int64(_ column: Int) -> Int64? {
        guard let statement = columnHandle(column) else { return nil }
        let position = Int32(column)
        switch sqlite3_column_type(statement, position) {
        case SQLITE_INTEGER: return sqlite3_column_int64(statement, position)
        case SQLITE_FLOAT: return Int64(exactly: sqlite3_column_double(statement, position))
        case SQLITE_TEXT: return string(column).flatMap { Int64($0) }
        default: return nil
        }
    }

    /// `int64(_:)` narrowed to `Int` (nil if it does not fit).
    public func int(_ column: Int) -> Int? {
        int64(column).flatMap { Int(exactly: $0) }
    }

    /// INTEGER/REAL as Double; TEXT only when it parses; otherwise nil.
    public func double(_ column: Int) -> Double? {
        guard let statement = columnHandle(column) else { return nil }
        let position = Int32(column)
        switch sqlite3_column_type(statement, position) {
        case SQLITE_INTEGER: return Double(sqlite3_column_int64(statement, position))
        case SQLITE_FLOAT: return sqlite3_column_double(statement, position)
        case SQLITE_TEXT: return string(column).flatMap { Double($0) }
        default: return nil
        }
    }

    /// Non-zero integer = true; nil for NULL or non-integers.
    public func bool(_ column: Int) -> Bool? {
        int64(column).map { $0 != 0 }
    }

    /// The column as UTF-8 text (embedded NULs preserved, invalid UTF-8 repaired); nil for NULL.
    public func string(_ column: Int) -> String? {
        guard let statement = columnHandle(column) else { return nil }
        let position = Int32(column)
        guard sqlite3_column_type(statement, position) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, position) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, position))
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }

    /// The column's bytes; nil for NULL. A zero-length blob is an empty `Data`, not nil.
    public func data(_ column: Int) -> Data? {
        guard let statement = columnHandle(column) else { return nil }
        let position = Int32(column)
        guard sqlite3_column_type(statement, position) != SQLITE_NULL else { return nil }
        let bytes = sqlite3_column_blob(statement, position)
        let count = Int(sqlite3_column_bytes(statement, position))
        guard count > 0 else { return Data() }
        guard let bytes else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// `data(_:)` as a byte array.
    public func bytes(_ column: Int) -> [UInt8]? {
        data(column).map { [UInt8]($0) }
    }

    // MARK: Internals

    private func liveHandle() throws -> OpaquePointer {
        guard connection.isOpen, let handle else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "statement used after it was finalized or its connection closed",
                              sql: sql)
        }
        return handle
    }

    private func columnHandle(_ column: Int) -> OpaquePointer? {
        guard connection.isOpen, let handle, column >= 0, column < Int(sqlite3_column_count(handle)) else {
            return nil
        }
        return handle
    }
}
