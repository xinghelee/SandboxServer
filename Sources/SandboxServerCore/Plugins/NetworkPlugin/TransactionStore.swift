import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// One captured request/response, kept in memory only.
struct CapturedTransaction: Sendable {
    let id: String
    let method: String
    let url: String
    let host: String
    let startedAtMs: Int
    var status: Int?
    var durationMs: Int?
    var reqHeaders: [String: String]
    var respHeaders: [String: String]
    var reqBodyPreview: String?
    var respBodyPreview: String?
    var reqBytes: Int
    var respBytes: Int
    var error: String?
    /// Unredacted request headers + full request body, retained **only** so `net_replay_request`
    /// can re-issue the request faithfully (auth header included). Never serialized into any DTO —
    /// the wire-facing `reqHeaders`/`reqBodyPreview` stay redacted/truncated.
    var reqHeadersRaw: [String: String]
    var reqBodyFull: Data?
}

// MARK: - Wire payloads (shared by REST list/detail and the WS 'net' channel)

struct NetSummary: Encodable, Sendable {
    let id, method, url: String
    let status: Int?
    let startedAt: Int
    let durationMs: Int?
    let reqBytes, respBytes: Int
}

struct NetStarted: Encodable, Sendable {
    let id, method, url: String
    let startedAt: Int
}

struct NetCompleted: Encodable, Sendable {
    let id, method, url: String
    let status: Int?
    let startedAt: Int
    let durationMs: Int?
    let reqBytes, respBytes: Int
    let error: String?
}

struct NetDetail: Encodable, Sendable {
    let id, method, url: String
    let status: Int?
    let startedAt: Int
    let durationMs: Int?
    let reqBytes, respBytes: Int
    let reqHeaders: [String: String]?
    let respHeaders: [String: String]?
    let reqBody: String?
    let respBody: String?
    let error: String?
}

/// Everything needed to faithfully re-issue a captured request (raw headers + full body).
struct ReplayPayload: Sendable {
    let method: String
    let url: String
    let headers: [String: String]
    let body: Data?
}

/// Actor-guarded bounded ring buffer. Evicts oldest by BOTH count and total bytes. Redacts
/// sensitive headers at write time. The single store that backs both the console and MCP.
actor TransactionStore {
    private var items: [CapturedTransaction] = [] // oldest first
    private var index: [String: Int] = [:]        // id -> position (rebuilt on eviction)
    private var totalBytes = 0
    private let maxCount: Int
    private let maxBytes: Int
    private var publisher: (any PluginContext)?
    /// Optional host hook to render an encrypted/encoded body as readable text. Display-only: it
    /// feeds the body PREVIEW shown in the console/MCP and nothing else — never the replay path
    /// (which uses `reqBodyFull`) nor the bytes the host app actually sends/receives.
    private var decoder: NetworkBodyDecoder?
    private var redacted: Set<String> = [
        "authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key",
    ]
    private let bodyPreviewLimit = 64 * 1024
    /// Cap on the full request body retained for replay. Bodies above this can't be replayed
    /// (the replay sends an empty body) — acceptable for a debug tool; keeps memory bounded.
    private let replayBodyLimit = 1024 * 1024

    init(maxCount: Int = 1000, maxBytes: Int = 8 * 1024 * 1024) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    func attach(context: any PluginContext) {
        publisher = context
        decoder = context.config.networkBodyDecoder
        for header in context.config.extraRedactedHeaders { redacted.insert(header.lowercased()) }
    }

    func detach() { publisher = nil; decoder = nil }

    func begin(id: String, method: String, url: URL?, headers: [String: String], reqBody: Data?) async {
        let urlString = url?.absoluteString ?? "(unknown)"
        let startedAt = Int(Date().timeIntervalSince1970 * 1000)
        let txn = CapturedTransaction(
            id: id, method: method, url: urlString, host: url?.host ?? "",
            startedAtMs: startedAt, status: nil, durationMs: nil,
            reqHeaders: redact(headers),
            respHeaders: [:],
            reqBodyPreview: preview(reqBody, direction: .request, url: urlString,
                                    method: method, headers: headers, contentType: headers["content-type"]),
            respBodyPreview: nil,
            reqBytes: reqBody?.count ?? 0, respBytes: 0, error: nil,
            reqHeadersRaw: headers,
            reqBodyFull: (reqBody?.count ?? 0) <= replayBodyLimit ? reqBody : nil
        )
        append(txn)
        await publisher?.publish(channel: .net, type: "request.started",
                                 payload: NetStarted(id: id, method: method, url: urlString, startedAt: startedAt))
    }

    func complete(id: String, status: Int?, headers: [String: String], body: Data?, contentType: String?) async {
        guard let pos = index[id] else { return }
        var txn = items[pos]
        let now = Int(Date().timeIntervalSince1970 * 1000)
        txn.status = status
        txn.durationMs = now - txn.startedAtMs
        txn.respHeaders = redact(headers)
        txn.respBodyPreview = preview(body, direction: .response, url: txn.url,
                                      method: txn.method, headers: headers, contentType: contentType)
        let added = body?.count ?? 0
        txn.respBytes = added
        totalBytes += added
        items[pos] = txn
        evictIfNeeded()
        await publisher?.publish(channel: .net, type: "request.completed", payload: completedPayload(txn))
    }

    func fail(id: String, error: Error) async {
        guard let pos = index[id] else { return }
        var txn = items[pos]
        txn.durationMs = Int(Date().timeIntervalSince1970 * 1000) - txn.startedAtMs
        txn.error = "\(error)"
        items[pos] = txn
        await publisher?.publish(channel: .net, type: "request.completed", payload: completedPayload(txn))
    }

    func list(method: String?, host: String?, statusClass: Int?, sinceMs: Int?, limit: Int) -> Page<NetSummary> {
        var filtered = items.reversed().filter { txn in
            (method.map { txn.method.caseInsensitiveCompare($0) == .orderedSame } ?? true) &&
            (host.map { txn.host.contains($0) } ?? true) &&
            (statusClass.map { (txn.status ?? 0) / 100 == $0 } ?? true) &&
            (sinceMs.map { txn.startedAtMs >= $0 } ?? true)
        }
        if filtered.count > limit { filtered = Array(filtered.prefix(limit)) }
        return Page(items: filtered.map(summary), nextCursor: nil)
    }

    func detail(id: String, include: Set<String>) -> NetDetail? {
        guard let pos = index[id] else { return nil }
        let txn = items[pos]
        return NetDetail(
            id: txn.id, method: txn.method, url: txn.url, status: txn.status,
            startedAt: txn.startedAtMs, durationMs: txn.durationMs,
            reqBytes: txn.reqBytes, respBytes: txn.respBytes,
            reqHeaders: include.contains("reqHeaders") ? txn.reqHeaders : nil,
            respHeaders: include.contains("respHeaders") ? txn.respHeaders : nil,
            reqBody: include.contains("reqBody") ? txn.reqBodyPreview : nil,
            respBody: include.contains("respBody") ? txn.respBodyPreview : nil,
            error: txn.error
        )
    }

    /// The raw material to re-issue a captured request (unredacted headers + full body), or nil
    /// if the id is unknown / has been evicted.
    func replayPayload(id: String) -> ReplayPayload? {
        guard let pos = index[id] else { return nil }
        let txn = items[pos]
        return ReplayPayload(method: txn.method, url: txn.url, headers: txn.reqHeadersRaw, body: txn.reqBodyFull)
    }

    func clear() -> Int {
        let n = items.count
        items.removeAll(); index.removeAll(); totalBytes = 0
        return n
    }

    var count: Int { items.count }

    // MARK: - Internals

    private func append(_ txn: CapturedTransaction) {
        items.append(txn)
        index[txn.id] = items.count - 1
        totalBytes += txn.reqBytes
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        var dirty = false
        while items.count > maxCount || (totalBytes > maxBytes && items.count > 1) {
            let removed = items.removeFirst()
            totalBytes -= (removed.reqBytes + removed.respBytes)
            dirty = true
        }
        if dirty { reindex() }
    }

    private func reindex() {
        index.removeAll(keepingCapacity: true)
        for (i, txn) in items.enumerated() { index[txn.id] = i }
    }

    private func summary(_ txn: CapturedTransaction) -> NetSummary {
        NetSummary(id: txn.id, method: txn.method, url: txn.url, status: txn.status,
                   startedAt: txn.startedAtMs, durationMs: txn.durationMs,
                   reqBytes: txn.reqBytes, respBytes: txn.respBytes)
    }

    private func completedPayload(_ txn: CapturedTransaction) -> NetCompleted {
        NetCompleted(id: txn.id, method: txn.method, url: txn.url, status: txn.status,
                     startedAt: txn.startedAtMs, durationMs: txn.durationMs,
                     reqBytes: txn.reqBytes, respBytes: txn.respBytes, error: txn.error)
    }

    private func redact(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            result[pair.key] = redacted.contains(pair.key.lowercased()) ? "<redacted>" : pair.value
        }
    }

    /// Build the human-readable body preview. The optional host `decoder` is consulted FIRST so an
    /// app can surface its own encrypted/encoded bodies; returning nil falls through to the built-in
    /// rendering. This is display-only — the bytes the host app sends/receives and the raw body kept
    /// for replay are untouched regardless of what the decoder does.
    private func preview(_ data: Data?, direction: NetworkBody.Direction, url: String,
                         method: String, headers: [String: String], contentType: String?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let decoder, let decoded = decoder(NetworkBody(
            direction: direction, url: url, method: method,
            headers: headers, contentType: contentType, body: data
        )) {
            return decoded.count > bodyPreviewLimit
                ? String(decoded.prefix(bodyPreviewLimit)) + "\n… (truncated, decoded \(decoded.count) chars total)"
                : decoded
        }
        // Built-in key-free transforms (gzip/zlib), magic-byte gated so they never touch plain text.
        if let inflated = KeylessBodyDecoder.decode(data) { return inflated }
        let isText = (contentType ?? "").range(of: "json|text|xml|x-www-form-urlencoded|javascript",
                                                options: .regularExpression) != nil
            || contentType == nil
        guard isText else { return "<binary \(data.count) bytes>" }
        let slice = data.prefix(bodyPreviewLimit)
        let body = String(data: slice, encoding: .utf8) ?? "<\(data.count) bytes, non-UTF8>"
        return data.count > bodyPreviewLimit ? body + "\n… (truncated, \(data.count) bytes total)" : body
    }
}
