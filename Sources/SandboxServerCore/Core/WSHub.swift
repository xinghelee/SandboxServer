import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Owns every live WebSocket connection and the single multiplexed channel protocol.
///
/// Wire envelope (server → client): `{ "channel", "type", "seq", "payload" }` with `seq`
/// monotonic per channel. Clients send `{ "op": "subscribe"|"unsubscribe", "channel" }`.
///
/// Fan-out never blocks the actor: each connection has a bounded outbound queue drained by its own
/// task (the single writer to that socket), so a backpressured or dead subscriber only stalls ITS
/// own queue — `publish` just enqueues and returns. A send failure prunes that connection; overflow
/// drops the OLDEST frame (the monotonic `seq` lets the client detect the gap).
actor WSHub {
    private final class Conn {
        let connection: any ServerConnection
        var channels: Set<String> = []
        let outbound: AsyncStream<[UInt8]>
        let yield: AsyncStream<[UInt8]>.Continuation
        var drain: Task<Void, Never>?
        init(_ connection: any ServerConnection, limit: Int) {
            self.connection = connection
            (outbound, yield) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(limit))
        }
    }

    private struct Envelope<Payload: Encodable>: Encodable {
        let channel: String
        let type: String
        let seq: Int
        let payload: Payload
    }

    private struct Control: Decodable {
        let op: String
        let channel: String
    }

    private var conns: [UInt64: Conn] = [:]
    private var seqByChannel: [String: Int] = [:]
    private let encoder = JSONEncoder()
    private let log: @Sendable (String) -> Void
    /// Max frames buffered per connection before the OLDEST is dropped. The control protocol carries
    /// tiny events, so a generous cap absorbs a brief stall without unbounded memory growth.
    private let outboundLimit: Int

    init(log: @escaping @Sendable (String) -> Void, outboundLimit: Int = 256) {
        self.log = log
        self.outboundLimit = max(1, outboundLimit)
    }

    // MARK: Connection lifecycle (driven by the nonisolated serve loop)

    private func add(_ connection: any ServerConnection) {
        let conn = Conn(connection, limit: outboundLimit)
        conns[connection.id] = conn
        let id = connection.id
        // Capture only the Sendable pieces (the stream + the connection), never the non-Sendable Conn
        // class — that keeps the drain task data-race-clean and avoids a Conn⇄Task retain cycle.
        let stream = conn.outbound
        // One drain task per connection — the ONLY caller of connection.send, so frames stay ordered
        // and no two sends race. A send failure (peer gone / reset) ends the loop and prunes the conn.
        conn.drain = Task { [weak self] in
            for await frame in stream {
                do { try await connection.send(frame) } catch { break }
            }
            await self?.prune(id)
        }
    }

    /// Tear a connection down exactly once — idempotent across the drain-task exit and the serve
    /// loop teardown (whichever reaches it first removes it; the other is a no-op).
    private func prune(_ id: UInt64) {
        guard let conn = conns.removeValue(forKey: id) else { return }
        conn.yield.finish() // ends the drain loop
        conn.drain?.cancel()
        conn.connection.close()
    }

    /// Enqueue one frame for a single connection without blocking the actor.
    private func enqueue(_ id: UInt64, _ frame: [UInt8]) {
        conns[id]?.yield.yield(frame)
    }

    private func handleControl(connectionID: UInt64, payload: [UInt8]) {
        guard let control = try? JSONDecoder().decode(Control.self, from: Data(payload)) else { return }
        switch control.op {
        case "subscribe": conns[connectionID]?.channels.insert(control.channel)
        case "unsubscribe": conns[connectionID]?.channels.remove(control.channel)
        default: break
        }
    }

    // MARK: Publishing

    /// Fan out an event to every connection subscribed to `channel`, stamping a per-channel seq.
    /// Pure actor work: enqueues to each subscriber's outbound queue and returns — it never awaits a
    /// socket, so one slow/dead subscriber can't stall the others or the control path.
    func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {
        let seq = (seqByChannel[channel.name] ?? 0) + 1
        seqByChannel[channel.name] = seq
        let envelope = Envelope(channel: channel.name, type: type, seq: seq, payload: payload)
        guard let data = try? encoder.encode(envelope) else { return }
        let frame = WebSocketCodec.encode(.text, [UInt8](data))
        for conn in conns.values where conn.channels.contains(channel.name) {
            conn.yield.yield(frame)
        }
    }

    var connectionCount: Int { conns.count }

    /// Number of live connections currently subscribed to `channel`.
    func subscriberCount(_ channel: WSChannel) -> Int {
        conns.values.filter { $0.channels.contains(channel.name) }.count
    }

    // MARK: Per-connection read loop (nonisolated; mutates state via isolated hops)

    /// Runs after the 101 handshake: reads frames, applies subscribe/unsubscribe, answers
    /// pings, and tears down on close/EOF. `leftover` is any bytes read past the handshake.
    nonisolated func serve(_ connection: any ServerConnection, leftover: [UInt8]) async {
        await add(connection)
        var buffer = leftover
        loop: while true {
            for frame in WebSocketCodec.decode(&buffer, maxPayload: WebSocketCodec.maxFramePayloadBytes) {
                switch frame.opcode {
                case .text:
                    await handleControl(connectionID: connection.id, payload: frame.payload)
                case .ping:
                    // Route the pong through the same outbound queue so it stays ordered behind any
                    // queued events and there's still exactly one writer to the socket.
                    await enqueue(connection.id, WebSocketCodec.encode(.pong, frame.payload))
                case .close:
                    // Echo a Close (the decoder yields a synthetic 1009 frame for an oversized
                    // frame), best-effort, then tear down.
                    await enqueue(connection.id, WebSocketCodec.encode(.close, frame.payload))
                    break loop
                default:
                    break
                }
            }
            do {
                guard let chunk = try await connection.receive() else { break }
                buffer.append(contentsOf: chunk)
            } catch { break }
        }
        await prune(connection.id)
    }
}
