import Foundation
import SQLite3

public struct SQLiteError: LocalizedError, Sendable, Equatable {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "Local database error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

/// One SQLite connection. Not thread-safe by design: each instance is owned by exactly one actor.
public final class SQLiteConnection {
    let handle: OpaquePointer
    public let readOnly: Bool
    var workspaceActivity: WorkspaceActivity?
    private var closed = false

    private func requireOpen() throws {
        guard !closed else { throw SQLiteError(code: SQLITE_MISUSE, message: "This workspace store has been retired") }
    }

    /// Called only by the owning store actor after workspace work and observers have stopped.
    /// Stale UI references subsequently fail closed instead of writing into a reused partition path.
    func close() {
        guard !closed else { return }
        closed = true
        sqlite3_close_v2(handle)
    }

    private func checkMutationLease(_ sql: String) throws {
        let statement = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(where: { statement.hasPrefix($0) }) else { return }
        // Durable request state must record an ambiguous/accepted outcome even after pause. Other network
        // materialisation carries its original scheduler lease and cannot alter a newly resumed workspace.
        let words = statement.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).map(String.init)
        let target = words.first == "UPDATE" ? words.dropFirst().first : (words.first == "DELETE" && words.dropFirst().first == "FROM" ? words.dropFirst(2).first : nil)
        if target == "OUTBOX" || target == "WRITES" { return }
        try workspaceActivity?.checkInheritedLease()
    }

    public init(path: String, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        self.readOnly = readOnly
        sqlite3_busy_timeout(db, 2_000)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA foreign_keys=ON")
        }
        try execute("PRAGMA temp_store=MEMORY")
        registerFunctions()
    }

    /// `amb_ifind(text, needle)`: the 1-based character position of `needle` in `text` ignoring case in any script, or 0
    /// (SQLite's own `LIKE` and `lower()` fold ASCII letters only).
    private func registerFunctions() {
        sqlite3_create_function_v2(handle, "amb_ifind", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, argv in
            guard let argv, let a = argv[0], let b = argv[1], let text = sqlite3_value_text(a), let find = sqlite3_value_text(b) else {
                sqlite3_result_int(context, 0); return
            }
            // Only called for text with letters beyond ASCII, which an all-ASCII name cannot contain (most names are):
            // decline those from the bytes, without building strings.
            let length = Int(sqlite3_value_bytes(a))
            if (0..<length).allSatisfy({ text[$0] < 0x80 }) { sqlite3_result_int(context, 0); return }
            let haystack = String(cString: text), needle = String(cString: find)
            guard !needle.isEmpty else { sqlite3_result_int(context, 1); return }
            guard let found = haystack.range(of: needle, options: .caseInsensitive) else { sqlite3_result_int(context, 0); return }
            sqlite3_result_int(context, Int32(haystack.distance(from: haystack.startIndex, to: found.lowerBound) + 1))
        }, nil, nil, nil)
    }

    deinit { if !closed { sqlite3_close_v2(handle) } }

    private func error(_ rc: Int32) -> SQLiteError { SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle))) }

    public func execute(_ sql: String) throws {
        try requireOpen()
        try checkMutationLease(sql)
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    public func prepare(_ sql: String) throws -> Statement {
        try requireOpen()
        try checkMutationLease(sql)
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        return Statement(statement: statement, connection: self)
    }

    /// Runs `body` in an IMMEDIATE transaction; rolls back on any thrown error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public var userVersion: Int {
        get throws {
            let s = try prepare("PRAGMA user_version")
            return try s.step() ? Int(s.int(0)) : 0
        }
    }

    public final class Statement {
        let statement: OpaquePointer
        unowned let connection: SQLiteConnection

        init(statement: OpaquePointer, connection: SQLiteConnection) { self.statement = statement; self.connection = connection }
        deinit { sqlite3_finalize(statement) }

        @discardableResult public func bind(_ values: [SQLValue]) throws -> Statement {
            try connection.requireOpen()
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .null: rc = sqlite3_bind_null(statement, index)
                case .int(let v): rc = sqlite3_bind_int64(statement, index, v)
                case .double(let v): rc = sqlite3_bind_double(statement, index, v)
                case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
                case .blob(let v): rc = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
                }
                guard rc == SQLITE_OK else { throw connection.error(rc) }
            }
            return self
        }

        /// Returns true when a row is available.
        public func step() throws -> Bool {
            try connection.requireOpen()
            if sqlite3_stmt_readonly(statement) == 0, let sql = sqlite3_sql(statement) {
                try connection.checkMutationLease(String(cString: sql))
            }
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW { return true }
            if rc == SQLITE_DONE { return false }
            throw connection.error(rc)
        }

        public func run(_ values: [SQLValue] = []) throws {
            try bind(values)
            while try step() {}
        }

        public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        public func text(_ column: Int32) -> String? {
            guard let c = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: c)
        }
        public func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }
}

extension Optional where Wrapped == String {
    var sql: SQLValue { map(SQLValue.text) ?? .null }
}

extension Optional where Wrapped == Double {
    var sql: SQLValue { map(SQLValue.double) ?? .null }
}
