import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// Exercises `HTTPConnectionReader.readBody` framing: exact-length reads, the request-body size
/// cap (413 defence), and short-EOF detection (no silent truncation). Uses a scripted in-memory
/// connection so no socket is involved.
final class TransportBodyTests: XCTestCase {
    /// Feeds pre-scripted byte chunks, then signals EOF (`nil`).
    private final class ScriptedConnection: ServerConnection, @unchecked Sendable {
        let id: UInt64 = 1
        private var chunks: [[UInt8]]
        private var idx = 0
        init(_ chunks: [[UInt8]]) { self.chunks = chunks }
        func receive() async throws -> [UInt8]? {
            guard idx < chunks.count else { return nil } // clean EOF
            defer { idx += 1 }
            return chunks[idx]
        }
        func send(_ bytes: [UInt8]) async throws {}
        func close() {}
    }

    func testReadsExactLengthAcrossChunks() async throws {
        let reader = HTTPConnectionReader(ScriptedConnection([[1, 2, 3], [4, 5]]))
        let body = try await reader.readBody(length: 5)
        XCTAssertEqual([UInt8](body), [1, 2, 3, 4, 5])
    }

    func testLeavesExcessBytesBufferedForNextRead() async throws {
        // One chunk overshoots the requested length; the remainder must survive for a follow-up read.
        let reader = HTTPConnectionReader(ScriptedConnection([[1, 2, 3, 4, 5, 6]]))
        let first = try await reader.readBody(length: 4)
        XCTAssertEqual([UInt8](first), [1, 2, 3, 4])
        let second = try await reader.readBody(length: 2)
        XCTAssertEqual([UInt8](second), [5, 6])
    }

    func testZeroLengthReturnsEmptyWithoutReading() async throws {
        let reader = HTTPConnectionReader(ScriptedConnection([])) // would EOF if touched
        let body = try await reader.readBody(length: 0)
        XCTAssertTrue(body.isEmpty)
    }

    func testOversizeBodyThrowsPayloadTooLargeBeforeReading() async {
        // The cap is checked against the declared length up front — no bytes need to be fed.
        let reader = HTTPConnectionReader(ScriptedConnection([]))
        await assertThrows(HTTPError.payloadTooLarge) {
            _ = try await reader.readBody(length: HTTPConnectionReader.maxBodyBytes + 1)
        }
    }

    func testShortEOFThrowsTruncatedBody() async {
        // Peer promises 10 bytes but closes after 3 — must surface as an error, not a silent 3 bytes.
        let reader = HTTPConnectionReader(ScriptedConnection([[1, 2, 3]]))
        await assertThrows(HTTPError.truncatedBody) {
            _ = try await reader.readBody(length: 10)
        }
    }

    // MARK: - Helper

    private func assertThrows(
        _ expected: HTTPError, _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as HTTPError {
            XCTAssertEqual("\(error)", "\(expected)", file: file, line: line)
        } catch {
            XCTFail("expected HTTPError.\(expected), got \(error)", file: file, line: line)
        }
    }
}
#endif
