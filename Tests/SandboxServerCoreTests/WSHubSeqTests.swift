import XCTest
import Foundation
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// D2: the WSHub resume contract — each channel carries its OWN monotonic `seq` (so a client can
/// detect gaps per channel), and the frame is the documented {channel,type,seq,payload} shape.
/// (WSHubFanoutTests already covers fan-out / pruning / overflow; this covers per-channel seq.)
final class WSHubSeqTests: XCTestCase {
    /// Minimal ServerConnection double: replays one subscribe frame, then parks; records sends.
    private final class RecConn: ServerConnection, @unchecked Sendable {
        let id: UInt64
        private let lock = NSLock()
        private var _sent: [[UInt8]] = []
        private var inbound: [[UInt8]]
        private var idx = 0
        private var _closed = false
        init(id: UInt64, subscribe: [UInt8]) { self.id = id; self.inbound = [subscribe] }
        var sent: [[UInt8]] { lock.withLock { _sent } }
        private var isClosed: Bool { lock.withLock { _closed } }
        func receive() async throws -> [UInt8]? {
            let next: [UInt8]? = lock.withLock {
                guard idx < inbound.count else { return nil }
                defer { idx += 1 }
                return inbound[idx]
            }
            if let next { return next }
            while !isClosed { try? await Task.sleep(nanoseconds: 10_000_000) }
            return nil
        }
        func send(_ bytes: [UInt8]) async throws { lock.withLock { _sent.append(bytes) } }
        func close() { lock.withLock { _closed = true } }
    }

    private func subscribe(_ channel: String) -> [UInt8] {
        WebSocketCodec.encode(.text, Array(#"{"op":"subscribe","channel":"\#(channel)"}"#.utf8))
    }

    private func frames(of raw: [[UInt8]]) -> [[String: Any]] {
        raw.compactMap { f in
            var buf = f
            guard let frame = WebSocketCodec.decode(&buf).first,
                  let obj = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    private func awaitUntil(_ timeout: TimeInterval = 2, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await cond()
    }

    func testSeqIsIndependentAndMonotonicPerChannel() async {
        let hub = WSHub(log: { _ in })
        let net = RecConn(id: 1, subscribe: subscribe("net"))
        let logs = RecConn(id: 2, subscribe: subscribe("logs"))
        Task { await hub.serve(net, leftover: []) }
        Task { await hub.serve(logs, leftover: []) }

        let ready = await awaitUntil {
            let net = await hub.subscriberCount(.net)
            let logs = await hub.subscriberCount(.logs)
            return net == 1 && logs == 1
        }
        XCTAssertTrue(ready, "both channels have a subscriber")

        for i in 1...3 { await hub.publish(channel: .net, type: "n", payload: ["i": i]) }
        for i in 1...3 { await hub.publish(channel: .logs, type: "l", payload: ["i": i]) }

        let delivered = await awaitUntil { net.sent.count == 3 && logs.sent.count == 3 }
        XCTAssertTrue(delivered, "each subscriber received its three frames")
        XCTAssertEqual(frames(of: net.sent).compactMap { $0["seq"] as? Int }, [1, 2, 3], "net seq is its own 1,2,3")
        XCTAssertEqual(frames(of: logs.sent).compactMap { $0["seq"] as? Int }, [1, 2, 3], "logs seq is independent 1,2,3")
        net.close(); logs.close()
    }

    func testFrameShapeRoundTrips() async {
        let hub = WSHub(log: { _ in })
        let net = RecConn(id: 1, subscribe: subscribe("net"))
        Task { await hub.serve(net, leftover: []) }
        _ = await awaitUntil { await hub.subscriberCount(.net) == 1 }

        await hub.publish(channel: .net, type: "request.started", payload: ["url": "https://example.com/x"])
        let got = await awaitUntil { net.sent.count == 1 }
        XCTAssertTrue(got)
        let obj = frames(of: net.sent).first
        XCTAssertEqual(obj?["channel"] as? String, "net")
        XCTAssertEqual(obj?["type"] as? String, "request.started")
        XCTAssertEqual(obj?["seq"] as? Int, 1)
        XCTAssertEqual((obj?["payload"] as? [String: Any])?["url"] as? String, "https://example.com/x")
        net.close()
    }
}
#endif
