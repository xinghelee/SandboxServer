import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore
#if canImport(SQLite3)
import SQLite3
#endif

/// C2: `Range:` parsing (incl. the previously-dropped suffix form) end-to-end through
/// `FilePlugin.read`, and opt-in DB row counts (`?counts=true`) so the table list stays cheap.
final class RangeAndCountsTests: XCTestCase {
    // MARK: - Range header parsing

    private func head(_ range: String?) -> HTTPRequestHead {
        var headers: [String: String] = [:]
        if let range { headers["range"] = range }
        return HTTPRequestHead(method: "GET", target: "/x", version: "HTTP/1.1", headers: headers)
    }

    func testByteRangeExplicit() {
        XCTAssertEqual(head("bytes=0-99").byteRange, .explicit(start: 0, end: 99))
        XCTAssertEqual(head("bytes=500-999").byteRange, .explicit(start: 500, end: 999))
    }

    func testByteRangeOpenEnded() {
        XCTAssertEqual(head("bytes=1000-").byteRange, .explicit(start: 1000, end: .max))
    }

    func testByteRangeSuffix() {
        XCTAssertEqual(head("bytes=-500").byteRange, .suffix(500))
        XCTAssertEqual(head("bytes=-1").byteRange, .suffix(1))
    }

    func testByteRangeMalformedReturnsNil() {
        XCTAssertNil(head(nil).byteRange)
        XCTAssertNil(head("items=0-1").byteRange)    // wrong unit
        XCTAssertNil(head("bytes=-0").byteRange)      // suffix of zero is meaningless (RFC 7233)
        XCTAssertNil(head("bytes=100-50").byteRange)  // end < start
        XCTAssertNil(head("bytes=abc-").byteRange)
        XCTAssertNil(head("bytes=-").byteRange)
    }

    // MARK: - FilePlugin suffix range read

    func testFilePluginSuffixRangeReturnsTail206() throws {
        let file = try writeTempFile(bytes: 1000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let req = SBRequest(method: "GET", path: "file", query: ["path": file.path], range: .suffix(500))
        let resp = FilePlugin.read(req, StubContext(roots: [file.deletingLastPathComponent()]))

        XCTAssertEqual(resp.status, 206)
        XCTAssertEqual(resp.headers["Content-Range"], "bytes 500-999/1000")
        guard case .stream(_, _, let total) = resp.body else { return XCTFail("expected a stream body") }
        XCTAssertEqual(total, 500, "suffix(500) should stream exactly the last 500 bytes")
    }

    func testFilePluginSuffixLargerThanFileClampsToWholeFile() throws {
        let file = try writeTempFile(bytes: 1000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        // bytes=-5000 on a 1000-byte file → the whole file, not a 416 (RFC 7233 §2.1 clamping).
        let req = SBRequest(method: "GET", path: "file", query: ["path": file.path], range: .suffix(5000))
        let resp = FilePlugin.read(req, StubContext(roots: [file.deletingLastPathComponent()]))

        XCTAssertEqual(resp.status, 206)
        XCTAssertEqual(resp.headers["Content-Range"], "bytes 0-999/1000")
        guard case .stream(_, _, let total) = resp.body else { return XCTFail("expected a stream body") }
        XCTAssertEqual(total, 1000)
    }

    func testFilePluginExplicitRangeStillWorks() throws {
        let file = try writeTempFile(bytes: 1000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let req = SBRequest(method: "GET", path: "file", query: ["path": file.path], range: .explicit(start: 10, end: 19))
        let resp = FilePlugin.read(req, StubContext(roots: [file.deletingLastPathComponent()]))

        XCTAssertEqual(resp.status, 206)
        XCTAssertEqual(resp.headers["Content-Range"], "bytes 10-19/1000")
        guard case .stream(_, _, let total) = resp.body else { return XCTFail("expected a stream body") }
        XCTAssertEqual(total, 10)
    }

    // MARK: - DB row counts are opt-in

    func testTablesOmitRowCountsByDefault() throws {
        let path = try makeTempDB(["t": 3, "u": 0])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tables = try SQLiteReader.tables(at: path)
        XCTAssertEqual(Set(tables.map(\.name)), ["t", "u"])
        XCTAssertTrue(tables.allSatisfy { $0.rowCount == nil }, "default list must not run COUNT(*)")
    }

    func testTablesIncludeRowCountsWhenRequested() throws {
        let path = try makeTempDB(["t": 3, "u": 0])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tables = try SQLiteReader.tables(at: path, includeCounts: true)
        let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.rowCount) })
        XCTAssertEqual(byName["t"], 3)
        XCTAssertEqual(byName["u"], 0)
    }

    // MARK: - Helpers

    private func writeTempFile(bytes count: Int) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbx-range-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("data.bin")
        try Data((0..<count).map { UInt8($0 % 256) }).write(to: file)
        return file
    }

    private func makeTempDB(_ tables: [String: Int]) throws -> String {
        let path = NSTemporaryDirectory() + "sbx-db-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw XCTSkip("could not create temp SQLite database")
        }
        defer { sqlite3_close_v2(db) }
        for (name, rows) in tables {
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE \(name)(a)", nil, nil, nil), SQLITE_OK)
            for i in 0..<rows {
                XCTAssertEqual(sqlite3_exec(db, "INSERT INTO \(name) VALUES (\(i))", nil, nil, nil), SQLITE_OK)
            }
        }
        return path
    }

    /// Minimal `PluginContext` exposing only the roots a read needs.
    private final class StubContext: PluginContext, @unchecked Sendable {
        let rootURLs: [URL]
        init(roots: [URL]) { self.rootURLs = roots }
        func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {}
        func extraRoots() -> [URL] { rootURLs }
        func hostValue<Value>(_ key: HostValueKey<Value>) -> Value? { nil }
        var config: SandboxConfig { SandboxConfig() }
        func log(_ message: @autoclosure () -> String) {}
    }
}
#endif
