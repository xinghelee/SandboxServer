import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif
// The OS-provided SQLite. SPM uses the bundled systemLibrary target; CocoaPods (single module)
// falls back to Apple's built-in SQLite3 module (with `s.libraries = 'sqlite3'`).
#if canImport(SandboxServerSystemSQLite)
import SandboxServerSystemSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif

enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    var description: String {
        switch self {
        case .open(let m): return "open failed: \(m)"
        case .prepare(let m): return "SQL error: \(m)"
        }
    }
}

/// Minimal read-only SQLite access over the system libsqlite3. Each call opens its own
/// `SQLITE_OPEN_READONLY` connection, so the host app's database is never mutated and a
/// separate connection sees committed WAL pages without checkpointing.
enum SQLiteReader {
    struct TableInfo: Encodable, Sendable { let name: String; let rowCount: Int }
    struct ColumnInfo: Encodable, Sendable { let name: String; let type: String; let pk: Bool; let notnull: Bool }
    struct ForeignKey: Encodable, Sendable { let from: String; let table: String; let to: String }
    struct Schema: Encodable, Sendable { let columns: [ColumnInfo]; let foreignKeys: [ForeignKey] }
    struct QueryResult: Encodable, Sendable {
        let columns: [String]
        let rows: [[JSONValue]]
        let nextCursor: String?
    }

    // MARK: - Connection

    private static func withConnection<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let msg = handle.map { cstr(sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.open(msg)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    // MARK: - Public reads

    static func tables(at path: String) throws -> [TableInfo] {
        try withConnection(path) { db in
            let names = try rawQuery(db,
                "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
                limit: 10_000).rows.compactMap { row -> String? in
                if case .string(let s) = row.first { return s } else { return nil }
            }
            return names.map { name in
                let count = (try? scalarInt(db, "SELECT COUNT(*) FROM \(quote(name))")) ?? -1
                return TableInfo(name: name, rowCount: count)
            }
        }
    }

    static func schema(at path: String, table: String) throws -> Schema {
        try withConnection(path) { db in
            let info = try rawQuery(db, "PRAGMA table_info(\(quote(table)))", limit: 10_000)
            let columns: [ColumnInfo] = info.rows.map { row in
                ColumnInfo(
                    name: text(row, index: info.columns.firstIndex(of: "name")),
                    type: text(row, index: info.columns.firstIndex(of: "type")),
                    pk: int(row, index: info.columns.firstIndex(of: "pk")) > 0,
                    notnull: int(row, index: info.columns.firstIndex(of: "notnull")) != 0
                )
            }
            let fkRaw = try rawQuery(db, "PRAGMA foreign_key_list(\(quote(table)))", limit: 10_000)
            let fks: [ForeignKey] = fkRaw.rows.map { row in
                ForeignKey(
                    from: text(row, index: fkRaw.columns.firstIndex(of: "from")),
                    table: text(row, index: fkRaw.columns.firstIndex(of: "table")),
                    to: text(row, index: fkRaw.columns.firstIndex(of: "to"))
                )
            }
            return Schema(columns: columns, foreignKeys: fks)
        }
    }

    /// Runs a read-only query (or browses a table). Writes naturally fail on the RO connection.
    static func query(at path: String, sql: String?, table: String?, limit: Int, offset: Int) throws -> QueryResult {
        try withConnection(path) { db in
            let statement: String
            let paged: Bool
            if let table, !table.isEmpty {
                statement = "SELECT * FROM \(quote(table)) LIMIT \(limit) OFFSET \(offset)"
                paged = true
            } else {
                statement = sql ?? "SELECT 1"
                paged = false
            }
            let result = try rawQuery(db, statement, limit: limit)
            let next = paged && result.rows.count >= limit ? String(offset + limit) : nil
            return QueryResult(columns: result.columns, rows: result.rows, nextCursor: next)
        }
    }

    // MARK: - Core stepping

    private struct RawRows { let columns: [String]; let rows: [[JSONValue]] }

    private static func rawQuery(_ db: OpaquePointer, _ sql: String, limit: Int) throws -> RawRows {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(cstr(sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let ncol = Int(sqlite3_column_count(stmt))
        let columns = (0..<ncol).map { cstr(sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[JSONValue]] = []
        while rows.count < limit {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append((0..<ncol).map { cell(stmt, Int32($0)) })
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.prepare(cstr(sqlite3_errmsg(db)))
            }
        }
        return RawRows(columns: columns, rows: rows)
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let r = try rawQuery(db, sql, limit: 1)
        if case .int(let n) = r.rows.first?.first { return n }
        return 0
    }

    private static func cell(_ stmt: OpaquePointer, _ i: Int32) -> JSONValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, i)))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        case SQLITE_BLOB: return .string("⟨blob \(Int(sqlite3_column_bytes(stmt, i))) bytes⟩")
        default:
            if let c = sqlite3_column_text(stmt, i) {
                let n = Int(sqlite3_column_bytes(stmt, i))
                return .string(String(decoding: UnsafeBufferPointer(start: c, count: n), as: UTF8.self))
            }
            return .string("")
        }
    }

    // MARK: - Helpers

    private static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func cstr(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)), as: UTF8.self)
    }

    private static func text(_ row: [JSONValue], index: Int?) -> String {
        guard let index, index < row.count, case .string(let s) = row[index] else { return "" }
        return s
    }

    private static func int(_ row: [JSONValue], index: Int?) -> Int {
        guard let index, index < row.count, case .int(let n) = row[index] else { return 0 }
        return n
    }
}
