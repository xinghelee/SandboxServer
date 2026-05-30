import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore
#if canImport(SQLite3)
import SQLite3
#endif

/// E2: the read-only DB connection additionally refuses ATTACH/DETACH (so user SQL can't read
/// other sandbox SQLite files) and rejects multi-statement input instead of silently running only
/// the first statement — while ordinary reads keep working.
final class SQLiteGuardTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "sbx-guard-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw XCTSkip("could not create a temp SQLite database")
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "CREATE TABLE t(a); INSERT INTO t VALUES (1),(2),(3);", nil, nil, nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testNormalSelectStillWorks() throws {
        let r = try SQLiteReader.query(at: path, sql: "SELECT a FROM t ORDER BY a", table: nil, limit: 10, offset: 0)
        XCTAssertEqual(r.rows.count, 3)
    }

    func testTableBrowseStillWorks() throws {
        let r = try SQLiteReader.query(at: path, sql: nil, table: "t", limit: 10, offset: 0)
        XCTAssertEqual(r.rows.count, 3)
    }

    func testAttachIsDenied() {
        // The authorizer denies ATTACH, so even a single ATTACH statement fails to prepare.
        XCTAssertThrowsError(
            try SQLiteReader.query(at: path, sql: "ATTACH DATABASE '\(path)' AS other", table: nil, limit: 10, offset: 0)
        )
    }

    func testMultipleStatementsAreRejected() {
        XCTAssertThrowsError(
            try SQLiteReader.query(at: path, sql: "SELECT 1; SELECT 2", table: nil, limit: 10, offset: 0)
        ) { err in
            guard case SQLiteError.multipleStatements = err else {
                return XCTFail("expected .multipleStatements, got \(err)")
            }
        }
    }
}
#endif
