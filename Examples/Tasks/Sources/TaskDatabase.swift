import Foundation
import SQLite3

// SQLite wants this for TEXT binds that it should copy (the Swift String is transient).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A tiny hand-rolled SQLite store for the task list — `Documents/tasks.sqlite`. Zero dependencies,
/// matching the SDK's own house style (raw `sqlite3` C API). This is the file the console's
/// **Databases** panel discovers and serves read-only, and against which you can run live SELECTs.
///
/// Not `Sendable` and not `@MainActor`: it is created and used **only** from the `@MainActor`
/// ``TaskStore``, so the open connection never crosses an isolation boundary. The work is trivial
/// (a handful of rows) so doing it synchronously on the main actor is fine for a demo.
final class TaskDatabase {
    private var db: OpaquePointer?
    let path: String

    init?() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        path = docs.appendingPathComponent("tasks.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS tasks(
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          title        TEXT    NOT NULL,
          done         INTEGER NOT NULL DEFAULT 0,
          priority     INTEGER NOT NULL DEFAULT 1,
          created_at   TEXT    NOT NULL,
          note_summary TEXT    NOT NULL DEFAULT ''
        );
        """)
    }

    deinit { sqlite3_close(db) }

    var isEmpty: Bool { count() == 0 }

    func count() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM tasks", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// All tasks, newest first. The view applies the user's sort/filter in memory.
    func fetchAll() -> [TaskItem] {
        var stmt: OpaquePointer?
        let sql = "SELECT id, title, done, priority, created_at, note_summary FROM tasks ORDER BY id DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()
        var items: [TaskItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(TaskItem(
                id: sqlite3_column_int64(stmt, 0),
                title: Self.text(stmt, 1),
                isDone: sqlite3_column_int(stmt, 2) != 0,
                priority: Priority(rawValue: Int(sqlite3_column_int(stmt, 3))) ?? .normal,
                createdAt: iso.date(from: Self.text(stmt, 4)) ?? Date(),
                noteSummary: Self.text(stmt, 5)
            ))
        }
        return items
    }

    /// Inserts a row and returns its new id (so the note file can be named after it).
    @discardableResult
    func insert(title: String, priority: Priority, isDone: Bool = false, createdAt: Date = Date()) -> Int64? {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO tasks(title, done, priority, created_at) VALUES(?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, isDone ? 1 : 0)
        sqlite3_bind_int(stmt, 3, Int32(priority.rawValue))
        sqlite3_bind_text(stmt, 4, ISO8601DateFormatter().string(from: createdAt), -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// Persists title / done / priority / note-summary for an existing task.
    func update(_ task: TaskItem) {
        var stmt: OpaquePointer?
        let sql = "UPDATE tasks SET title=?, done=?, priority=?, note_summary=? WHERE id=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, task.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, task.isDone ? 1 : 0)
        sqlite3_bind_int(stmt, 3, Int32(task.priority.rawValue))
        sqlite3_bind_text(stmt, 4, task.noteSummary, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, task.id)
        sqlite3_step(stmt)
    }

    func setDone(id: Int64, done: Bool) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tasks SET done=? WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, done ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func delete(id: Int64) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM tasks WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    func deleteAll() { exec("DELETE FROM tasks") }

    // MARK: - Helpers

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}
