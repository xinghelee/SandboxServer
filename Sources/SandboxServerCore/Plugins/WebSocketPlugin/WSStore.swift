import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

enum WSDir: String, Sendable { case sent, received }
enum WSConnState: String, Sendable { case opening, open, closed, failed }

/// One captured WebSocket connection (kept in memory only).
struct WSConnection: Sendable {
    let id: String
    let url: String
    let host: String
    let startedAtMs: Int
    var state: WSConnState
    var closedAtMs: Int?
    var closeReason: String?
    var error: String?
    var messageCount: Int
}

struct WSMessageRecord: Sendable {
    let id: String
    let connId: String
    let dir: WSDir
    let opcode: String // "text" | "binary"
    let preview: String?
    let size: Int
    let ts: Int
    let seq: Int
}

// MARK: - Wire payloads (REST + the `ws` WS channel)

struct WSConnSummary: Encodable, Sendable {
    let id, url, host: String
    let startedAt: Int
    let state: String
    let closedAt: Int?
    let messageCount: Int
}

struct WSConnDetail: Encodable, Sendable {
    let id, url, host: String
    let startedAt: Int
    let state: String
    let closedAt: Int?
    let closeReason: String?
    let error: String?
    let messageCount: Int
}

struct WSMsgSummary: Encodable, Sendable {
    let id, connId: String
    let direction: String
    let opcode: String
    let preview: String?
    let size: Int
    let ts: Int
    let seq: Int
}

struct WSOpenedPayload: Encodable, Sendable {
    let id, url, host: String
    let startedAt: Int
}

struct WSClosedPayload: Encodable, Sendable {
    let id: String
    let state: String
    let closedAt: Int
    let closeReason: String?
    let error: String?
}

/// Actor-guarded bounded store for captured WebSocket connections + messages — the WS analogue of
/// `TransactionStore`. Connections evict oldest-first by count; each connection keeps a bounded,
/// per-connection message ring with a monotonic `seq`.
actor WSStore {
    private var conns: [WSConnection] = [] // oldest first
    private var connIndex: [String: Int] = [:]
    private var messages: [String: [WSMessageRecord]] = [:] // connId -> oldest-first
    private var seqByConn: [String: Int] = [:]
    private var publisher: (any PluginContext)?
    private let maxConns: Int
    private let maxMsgsPerConn: Int

    init(maxConns: Int = 200, maxMsgsPerConn: Int = 2000) {
        self.maxConns = maxConns
        self.maxMsgsPerConn = maxMsgsPerConn
    }

    func attach(context: any PluginContext) { publisher = context }
    func detach() { publisher = nil }

    func open(id: String, url: String, host: String) async {
        guard connIndex[id] == nil else { return } // first interception wins
        let startedAt = Int(Date().timeIntervalSince1970 * 1000)
        conns.append(WSConnection(id: id, url: url, host: host, startedAtMs: startedAt,
                                  state: .open, closedAtMs: nil, closeReason: nil, error: nil, messageCount: 0))
        connIndex[id] = conns.count - 1
        messages[id] = []
        seqByConn[id] = 0
        evictIfNeeded()
        await publisher?.publish(channel: .ws, type: "connection.opened",
                                 payload: WSOpenedPayload(id: id, url: url, host: host, startedAt: startedAt))
    }

    func record(connId: String, dir: WSDir, opcode: String, preview: String?, size: Int) async {
        guard let pos = connIndex[connId] else { return }
        let seq = (seqByConn[connId] ?? 0) + 1
        seqByConn[connId] = seq
        let msg = WSMessageRecord(id: UUID().uuidString, connId: connId, dir: dir, opcode: opcode,
                                  preview: preview, size: size, ts: Int(Date().timeIntervalSince1970 * 1000), seq: seq)
        var list = messages[connId] ?? []
        list.append(msg)
        if list.count > maxMsgsPerConn { list.removeFirst(list.count - maxMsgsPerConn) }
        messages[connId] = list
        conns[pos].messageCount += 1
        await publisher?.publish(channel: .ws, type: "message", payload: summary(msg))
    }

    func close(connId: String, state: WSConnState, reason: String?, error: String?) async {
        guard let pos = connIndex[connId] else { return }
        guard conns[pos].state == .open || conns[pos].state == .opening else { return } // idempotent
        let now = Int(Date().timeIntervalSince1970 * 1000)
        conns[pos].state = state
        conns[pos].closedAtMs = now
        conns[pos].closeReason = reason
        conns[pos].error = error
        await publisher?.publish(channel: .ws, type: "connection.closed",
                                 payload: WSClosedPayload(id: connId, state: state.rawValue, closedAt: now,
                                                          closeReason: reason, error: error))
    }

    func listConnections(limit: Int) -> Page<WSConnSummary> {
        let items = conns.reversed().prefix(limit).map {
            WSConnSummary(id: $0.id, url: $0.url, host: $0.host, startedAt: $0.startedAtMs,
                          state: $0.state.rawValue, closedAt: $0.closedAtMs, messageCount: $0.messageCount)
        }
        return Page(items: Array(items), nextCursor: nil)
    }

    func detail(id: String) -> WSConnDetail? {
        guard let pos = connIndex[id] else { return nil }
        let c = conns[pos]
        return WSConnDetail(id: c.id, url: c.url, host: c.host, startedAt: c.startedAtMs, state: c.state.rawValue,
                            closedAt: c.closedAtMs, closeReason: c.closeReason, error: c.error, messageCount: c.messageCount)
    }

    func messagesFor(connId: String, limit: Int) -> Page<WSMsgSummary>? {
        guard let list = messages[connId] else { return nil }
        return Page(items: list.suffix(limit).map(summary), nextCursor: nil) // oldest-first, newest tail
    }

    func clear() -> Int {
        let n = conns.count
        conns.removeAll(); connIndex.removeAll(); messages.removeAll(); seqByConn.removeAll()
        return n
    }

    // MARK: - Internals

    private func summary(_ m: WSMessageRecord) -> WSMsgSummary {
        WSMsgSummary(id: m.id, connId: m.connId, direction: m.dir.rawValue, opcode: m.opcode,
                     preview: m.preview, size: m.size, ts: m.ts, seq: m.seq)
    }

    private func evictIfNeeded() {
        while conns.count > maxConns {
            let removed = conns.removeFirst()
            messages[removed.id] = nil
            seqByConn[removed.id] = nil
        }
        connIndex.removeAll(keepingCapacity: true)
        for (i, c) in conns.enumerated() { connIndex[c.id] = i }
    }
}
