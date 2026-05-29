import XCTest
import Foundation
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// Verifies the WSHub fan-out contract: a slow/dead subscriber cannot stall the others, a failed
/// send prunes the connection, and a bounded outbound queue drops the OLDEST frame on overflow while
/// preserving order + per-channel seq. Uses in-memory ServerConnection doubles — no socket.
final class WSHubFanoutTests: XCTestCase {
    /// An async gate: send() can park on it until openGate(); `entered` lets a test detect that the
    /// drain task has actually reached the blocked send.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0
        func wait() async {
            entered += 1
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func openGate() {
            open = true
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
    }

    private enum SendMode {
        case record
        case throwError
        case gated(Gate)
    }

    /// receive() replays `inbound` once then parks (polling for close); send() behaves per `mode`.
    private final class FakeConn: ServerConnection, @unchecked Sendable {
        let id: UInt64
        private let lock = NSLock()
        private var _sent: [[UInt8]] = []
        private var inbound: [[UInt8]]
        private var idx = 0
        private var _closed = false
        private let mode: SendMode

        init(id: UInt64, inbound: [[UInt8]], mode: SendMode) {
            self.id = id
            self.inbound = inbound
            self.mode = mode
        }

        var sent: [[UInt8]] { lock.withLock { _sent } }
        var sentCount: Int { lock.withLock { _sent.count } }
        private var isClosed: Bool { lock.withLock { _closed } }

        func receive() async throws -> [UInt8]? {
            let next: [UInt8]? = lock.withLock {
                guard idx < inbound.count else { return nil }
                defer { idx += 1 }
                return inbound[idx]
            }
            if let next { return next }
            // Inbound exhausted: stay "connected" (a quiet client) until closed.
            while !isClosed { try? await Task.sleep(nanoseconds: 10_000_000) }
            return nil
        }

        func send(_ bytes: [UInt8]) async throws {
            switch mode {
            case .record: break
            case .throwError: throw NSError(domain: "test", code: 1)
            case .gated(let gate): await gate.wait()
            }
            lock.withLock { _sent.append(bytes) }
        }

        func close() { lock.withLock { _closed = true } }
    }

    private let subscribeNet = WebSocketCodec.encode(.text, Array(#"{"op":"subscribe","channel":"net"}"#.utf8))

    private func awaitUntil(_ timeout: TimeInterval = 2, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await cond()
    }

    /// Decode the `seq` out of each recorded server→client text frame.
    private func seqs(of frames: [[UInt8]]) -> [Int] {
        frames.compactMap { f in
            var buf = f
            guard let frame = WebSocketCodec.decode(&buf).first,
                  let obj = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
                  let s = obj["seq"] as? Int else { return nil }
            return s
        }
    }

    func testSlowSubscriberDoesNotStallOthers() async {
        let hub = WSHub(log: { _ in })
        let stuck = Gate() // never opened → this subscriber's send never completes
        let slow = FakeConn(id: 1, inbound: [subscribeNet], mode: .gated(stuck))
        let fast = FakeConn(id: 2, inbound: [subscribeNet], mode: .record)
        Task { await hub.serve(slow, leftover: []) }
        Task { await hub.serve(fast, leftover: []) }

        let bothSubscribed = await awaitUntil { await hub.subscriberCount(.net) == 2 }
        XCTAssertTrue(bothSubscribed, "both subscribed")
        await hub.publish(channel: .net, type: "x", payload: ["k": 1])

        let fastGot = await awaitUntil { fast.sentCount >= 1 }
        XCTAssertTrue(fastGot, "fast subscriber received the event")
        XCTAssertEqual(slow.sentCount, 0, "slow subscriber is stalled in send and got nothing — but didn't block fast")

        slow.close(); fast.close(); await stuck.openGate() // wind down
    }

    func testSendFailurePrunesConnection() async {
        let hub = WSHub(log: { _ in })
        let bad = FakeConn(id: 1, inbound: [subscribeNet], mode: .throwError)
        Task { await hub.serve(bad, leftover: []) }

        let subscribed = await awaitUntil { await hub.subscriberCount(.net) == 1 }
        XCTAssertTrue(subscribed, "subscribed")
        await hub.publish(channel: .net, type: "x", payload: ["k": 1])

        let pruned = await awaitUntil { await hub.connectionCount == 0 }
        XCTAssertTrue(pruned, "a connection whose send throws is pruned")
        bad.close()
    }

    func testOverflowDropsOldestPreservingOrderAndSeq() async {
        let hub = WSHub(log: { _ in }, outboundLimit: 2)
        let gate = Gate()
        let slow = FakeConn(id: 1, inbound: [subscribeNet], mode: .gated(gate))
        Task { await hub.serve(slow, leftover: []) }
        let subscribed = await awaitUntil { await hub.subscriberCount(.net) == 1 }
        XCTAssertTrue(subscribed, "subscribed")

        // Warm-up event (seq 1): the drain pulls it and parks on the gated send, leaving the queue empty.
        await hub.publish(channel: .net, type: "x", payload: ["k": 1])
        let parked = await awaitUntil { await gate.entered >= 1 }
        XCTAssertTrue(parked, "drain parked on the first send")

        // Five more (seq 2..6) while the drain is parked; queue limit 2 keeps only the newest two (5,6).
        for _ in 0..<5 { await hub.publish(channel: .net, type: "x", payload: ["k": 1]) }

        await gate.openGate()
        let delivered = await awaitUntil { slow.sentCount == 3 }
        XCTAssertTrue(delivered, "in-flight + newest two delivered")
        XCTAssertEqual(seqs(of: slow.sent), [1, 5, 6], "oldest buffered (2,3,4) dropped; order + seq preserved")

        slow.close()
    }
}
#endif
