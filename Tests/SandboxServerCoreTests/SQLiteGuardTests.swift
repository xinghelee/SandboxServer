import XCTest
import Foundation
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

    func testBlobCellsIncludeBoundedPreview() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE b(payload BLOB); INSERT INTO b VALUES (X'626C6F622D74657874');", nil, nil, nil), SQLITE_OK)

        let r = try SQLiteReader.query(at: path, sql: nil, table: "b", limit: 10, offset: 0)
        guard case .object(let blob)? = r.rows.first?.first else {
            return XCTFail("expected BLOB cells to be encoded as an object")
        }
        XCTAssertEqual(blob["kind"], .string("blob"))
        XCTAssertEqual(blob["bytes"], .int(9))
        XCTAssertEqual(blob["previewBytes"], .int(9))
        XCTAssertEqual(blob["truncated"], .bool(false))
        guard case .string(let base64)? = blob["base64"] else {
            return XCTFail("expected BLOB preview base64")
        }
        XCTAssertEqual(Data(base64Encoded: base64), Data("blob-text".utf8))
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
