import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore
#if canImport(Darwin)
import Darwin

/// D4: a peer that connects and sends a partial request then stalls (slow-loris) must be dropped
/// by the request read timeout. With the timeout made injectable, the test runs in ~1s instead of
/// waiting the 30s production default.
final class ReadTimeoutTests: XCTestCase {
    func testSlowLorisConnectionIsClosedByReadTimeout() async throws {
        let server = SandboxServerCore()
        let result = await server.start(SandboxConfig(
            bindingPolicy: .loopback, auth: .none, builtInPlugins: .none, preferredPort: 0, requestReadTimeout: 0.5
        ))
        guard case .started(let info) = result else { return XCTFail("server failed to start: \(result)") }
        let port = UInt16(info.port)

        // A request line + one header, but NO terminating CRLFCRLF — the reader keeps waiting.
        let partial = "GET /__sandbox/api/v1/healthz HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        let elapsed = secondsUntilClose(port: port, partial: partial, clientCapSeconds: 3)
        await server.stop()

        let e = try XCTUnwrap(elapsed, "could not connect to the server")
        XCTAssertLessThan(e, 1.5, "the stalled connection should close shortly after the 0.5s read timeout (was \(e)s)")
    }

    func testDefaultTimeoutKeepsAStalledConnectionOpenLonger() async throws {
        let server = SandboxServerCore()
        // Default requestReadTimeout (30s): the same stall must NOT be closed within ~1s.
        let result = await server.start(SandboxConfig(
            bindingPolicy: .loopback, auth: .none, builtInPlugins: .none, preferredPort: 0
        ))
        guard case .started(let info) = result else { return XCTFail("server failed to start: \(result)") }
        let port = UInt16(info.port)

        let partial = "GET /__sandbox/api/v1/healthz HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        let elapsed = secondsUntilClose(port: port, partial: partial, clientCapSeconds: 1)
        await server.stop()

        let e = try XCTUnwrap(elapsed, "could not connect to the server")
        XCTAssertGreaterThanOrEqual(e, 0.9, "with the 30s default, the connection must stay open past 1s (was \(e)s)")
    }

    /// Connects, sends `partial`, then blocks in recv until the server closes the connection (EOF)
    /// or the client-side cap elapses. Returns the elapsed seconds, or nil if it couldn't connect.
    private func secondsUntilClose(port: UInt16, partial: String, clientCapSeconds: Int) -> Double? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }

        var tv = timeval(tv_sec: clientCapSeconds, tv_usec: 0) // bound the recv so the test can't hang
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let bytes = Array(partial.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

        let start = Date()
        var chunk = [UInt8](repeating: 0, count: 1024)
        // Returns 0 on EOF (server closed), -1 on the client recv timeout, or >0 if the server sent
        // a response before closing — in every case the wall-clock to first wake tells us when the
        // server acted (or that it didn't, when it equals the client cap).
        _ = recv(fd, &chunk, chunk.count, 0)
        return Date().timeIntervalSince(start)
    }
}
#endif
#endif
