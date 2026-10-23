import Foundation
import CSQLite

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?
    public var description: String { "SQLite error \(code): \(message)\(sql.map { " — \($0)" } ?? "")" }
}

/// A value bindable to / readable from SQLite.
public enum SQLValue: Hashable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row with typed column accessors.
public struct Row {
    fileprivate let columns: [String: Int]
    fileprivate let values: [SQLValue]

    public subscript(_ name: String) -> SQLValue { columns[name].map { values[$0] } ?? .null }
    public subscript(_ index: Int) -> SQLValue { values[index] }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }
    public func int(_ name: String) -> Int? {
        switch self[name] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .text(let s): return Int(s)
        default: return nil
        }
    }
    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .text(let s): return Double(s)
        default: return nil
        }
    }
    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }
    public func data(_ name: String) -> Data? {
        if case .blob(let d) = self[name] { return d }
        return nil
    }
}

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, thread-safe wrapper around a SQLite connection. All access is serialised by a
/// recursive lock, which keeps the API synchronous and simple for callers on any thread.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var statementCache: [String: OpaquePointer] = [:]
    public let path: String

    /// Opens (or creates) a database. Pass ":memory:" for an in-memory database.
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
        }
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        for stmt in statementCache.values { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    private func error(_ rc: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    /// Executes one or more statements without parameters.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg, sql: sql)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        statementCache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLBindable], sql: String) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p.sqlValue {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_PTR)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT_PTR)
                }
            }
            if rc != SQLITE_OK { throw error(rc, sql) }
        }
    }

    /// Runs a statement that returns no rows. Returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ params: SQLBindable...) throws -> Int {
        try run(sql, params: params)
    }

    @discardableResult
    public func run(_ sql: String, params: [SQLBindable]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, params, sql: sql)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: SQLBindable...) throws -> [Row] {
        try query(sql, params: params)
    }

    public func query(_ sql: String, params: [SQLBindable]) throws -> [Row] {
        var rows: [Row] = []
        try forEach(sql, params: params) { rows.append($0) }
        return rows
    }

    /// Streams rows without materialising the whole result — used for large graph loads.
    public func forEach(_ sql: String, params: [SQLBindable] = [], _ body: (Row) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, params, sql: sql)
        let count = sqlite3_column_count(stmt)
        var columns: [String: Int] = [:]
        for i in 0..<count { columns[String(cString: sqlite3_column_name(stmt, i))] = Int(i) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: values.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), n > 0 { values.append(.blob(Data(bytes: p, count: n))) }
                    else { values.append(.blob(Data())) }
                default: values.append(.null)
                }
            }
            try body(Row(columns: columns, values: values))
        }
    }

    public func scalarInt(_ sql: String, _ params: SQLBindable...) throws -> Int {
        guard let row = try query(sql, params: params).first else { return 0 }
        switch row[0] {
        case .int(let v): return Int(v)
        case .double(let d): return Int(d)
        default: return 0
        }
    }

    /// Runs `body` inside a transaction (nested calls use savepoints).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let name = "sp_\(UInt32.random(in: 0...UInt32.max))"
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Online backup to another file using SQLite's backup API (safe while the DB is in use).
    public func backup(to destinationPath: String) throws {
        lock.lock(); defer { lock.unlock() }
        var dest: OpaquePointer?
        guard sqlite3_open(destinationPath, &dest) == SQLITE_OK else {
            sqlite3_close(dest)
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot open backup destination", sql: nil)
        }
        defer { sqlite3_close(dest) }
        guard let bk = sqlite3_backup_init(dest, "main", handle, "main") else {
            throw SQLiteError(code: sqlite3_errcode(dest), message: String(cString: sqlite3_errmsg(dest)), sql: nil)
        }
        let rc = sqlite3_backup_step(bk, -1)
        sqlite3_backup_finish(bk)
        guard rc == SQLITE_DONE else { throw SQLiteError(code: rc, message: "backup failed", sql: nil) }
    }

    /// Restores this database's contents from a backup file.
    public func restore(from sourcePath: String) throws {
        lock.lock(); defer { lock.unlock() }
        for stmt in statementCache.values { sqlite3_finalize(stmt) }
        statementCache.removeAll()
        var src: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(src)
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot open backup source", sql: nil)
        }
        defer { sqlite3_close(src) }
        guard let bk = sqlite3_backup_init(handle, "main", src, "main") else { throw error(sqlite3_errcode(handle), nil) }
        let rc = sqlite3_backup_step(bk, -1)
        sqlite3_backup_finish(bk)
        guard rc == SQLITE_DONE else { throw SQLiteError(code: rc, message: "restore failed", sql: nil) }
    }
}
