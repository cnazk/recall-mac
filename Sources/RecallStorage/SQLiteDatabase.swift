import Foundation
import SQLite3
import RecallCore

/// Errors surfaced by the thin SQLite wrapper.
public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    case exec(String)

    public var description: String {
        switch self {
        case .open(let message): "sqlite open failed: \(message)"
        case .prepare(let message): "sqlite prepare failed: \(message)"
        case .step(let message): "sqlite step failed: \(message)"
        case .exec(let message): "sqlite exec failed: \(message)"
        }
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper over the system SQLite.
///
/// We talk to `libsqlite3` directly rather than taking a dependency: the surface we need
/// is small, and it keeps the app buildable offline with no third-party code in the
/// process that handles clipboard content.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens a database file, or an in-process temporary database when `path` is nil.
    init(path: String?) throws {
        let target = path ?? ":memory:"
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        flags |= SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(target, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw SQLiteError.open(message)
        }
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA synchronous = NORMAL;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw SQLiteError.exec(message)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(lastErrorMessage)
        }
        return Statement(statement: statement, database: self)
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bind(bindings)
        try statement.run()
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], row: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bind(bindings)
        var results: [T] = []
        while try statement.step() {
            results.append(try row(Row(statement: statement)))
        }
        return results
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
}

/// A value bindable to a statement parameter.
enum SQLiteValue {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }
    static func date(_ value: Date) -> SQLiteValue { .double(value.timeIntervalSince1970) }
    static func date(_ value: Date?) -> SQLiteValue { value.map { .double($0.timeIntervalSince1970) } ?? .null }
    static func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
}

final class Statement {
    fileprivate let statement: OpaquePointer
    private unowned let database: SQLiteDatabase

    fileprivate init(statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    func finalize() {
        sqlite3_finalize(statement)
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .integer(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                status = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                status = sqlite3_bind_text(statement, index, string, -1, transientDestructor)
            case .blob(let data):
                status = data.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transientDestructor)
                    }
            }
            guard status == SQLITE_OK else { throw SQLiteError.prepare(database.lastErrorMessage) }
        }
    }

    /// Advances the cursor; returns false once the result set is exhausted.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(database.lastErrorMessage)
        }
    }

    func run() throws {
        while try step() {}
    }
}

/// Column accessors for the current row of a stepped statement.
struct Row {
    fileprivate let statement: Statement

    func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement.statement, index) }
    func bool(_ index: Int32) -> Bool { int(index) != 0 }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement.statement, index) }

    func string(_ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement.statement, index) else { return nil }
        return String(cString: pointer)
    }

    func data(_ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement.statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement.statement, index)))
    }
}
