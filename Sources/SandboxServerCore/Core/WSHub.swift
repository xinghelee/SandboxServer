import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Owns every live WebSocket connection and the single multiplexed channel protocol.
///
/// Wire envelope (server → client): `{ "channel", "type", "seq", "payload" }` with `seq`
/// monotonic per channel. Clients send `{ "op": "subscribe"|"unsubscribe", "channel" }`.
actor WSHub {
    private struct Conn {
        let connection: any ServerConnection
        var channels: Set<String> = []
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

    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    // MARK: Connection lifecycle (driven by the nonisolated serve loop)

    private func add(_ connection: any ServerConnection) { conns[connection.id] = Conn(connection: connection) }
    private func remove(_ id: UInt64) { conns[id] = nil }

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
    func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {
        let seq = (seqByChannel[channel.name] ?? 0) + 1
        seqByChannel[channel.name] = seq
        let envelope = Envelope(channel: channel.name, type: type, seq: seq, payload: payload)
        guard let data = try? encoder.encode(envelope) else { return }
        let frame = WebSocketCodec.encode(.text, [UInt8](data))
        let targets = conns.values.filter { $0.channels.contains(channel.name) }.map(\.connection)
        for target in targets { try? await target.send(frame) }
    }

    var connectionCount: Int { conns.count }

    // MARK: Per-connection read loop (nonisolated; mutates state via isolated hops)

    /// Runs after the 101 handshake: reads frames, applies subscribe/unsubscribe, answers
    /// pings, and tears down on close/EOF. `leftover` is any bytes read past the handshake.
    nonisolated func serve(_ connection: any ServerConnection, leftover: [UInt8]) async {
        await add(connection)
        var buffer = leftover
        loop: while true {
            for frame in WebSocketCodec.decode(&buffer) {
                switch frame.opcode {
                case .text:
                    await handleControl(connectionID: connection.id, payload: frame.payload)
                case .ping:
                    try? await connection.send(WebSocketCodec.encode(.pong, frame.payload))
                case .close:
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
        await remove(connection.id)
        connection.close()
    }
}
