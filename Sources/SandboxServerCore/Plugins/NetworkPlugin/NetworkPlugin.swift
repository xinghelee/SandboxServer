import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE in v1. Captures URLSession traffic into an actor-guarded ring buffer and streams it
/// over the `net` WebSocket channel, so the whole transport → plugin → console → MCP stack is
/// exercised end-to-end on day one. Replay is live too: `POST requests/{id}/replay` re-issues a
/// captured request (optionally overriding headers/body) through the non-capturing internal session.
final class NetworkPlugin: SandboxPlugin, @unchecked Sendable {
    let id = PluginID.net
    private let store = TransactionStore()

    init() {}

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Network", panelKey: "net",
            routes: ["GET requests", "GET requests/{id}", "DELETE requests", "POST requests/{id}/replay"],
            channels: [WSChannel.net.name],
            mcpTools: [
                .init(name: "net_list_requests", title: "List network requests",
                      description: "List captured HTTP requests (newest first), optionally filtered.",
                      backingMethod: "GET", backingPathSuffix: "requests", readOnlyHint: true, destructiveHint: false),
                .init(name: "net_get_request", title: "Get request detail",
                      description: "Full headers and bodies for one captured request.",
                      backingMethod: "GET", backingPathSuffix: "requests/{id}", readOnlyHint: true, destructiveHint: false),
                .init(name: "net_replay_request", title: "Replay request",
                      description: "Re-issue a captured request, optionally overriding headers/body; returns the new response.",
                      backingMethod: "POST", backingPathSuffix: "requests/{id}/replay", readOnlyHint: false, destructiveHint: false),
                .init(name: "net_clear", title: "Clear captured requests",
                      description: "Discard all captured requests.",
                      backingMethod: "DELETE", backingPathSuffix: "requests", readOnlyHint: false, destructiveHint: true),
            ],
            limitations: [
                "Captures URLSession.shared, .default and .ephemeral configurations.",
                "Not captured: background sessions, WKWebView, raw sockets, and non-HTTP(S) schemes.",
            ]
        )
    }

    func channels() -> [WSChannel] { [.net] }

    func activate(context: any PluginContext) async throws {
        await store.attach(context: context)
        SandboxURLProtocol.store = store
        SandboxURLProtocol.isEnabled = true
        URLProtocol.registerClass(SandboxURLProtocol.self)   // covers URLSession.shared
        ConfigurationSwizzler.installIfNeeded()              // covers sessions from .default/.ephemeral
        context.log("network capture active")
    }

    func deactivate() async {
        SandboxURLProtocol.isEnabled = false
        URLProtocol.unregisterClass(SandboxURLProtocol.self)
        await store.detach()
    }

    func routes() -> [HTTPRoute] {
        let store = self.store
        return [
            HTTPRoute("GET", "requests", annotations: .read) { req, _ in
                let page = await store.list(
                    method: req.query["method"],
                    host: req.query["host"],
                    statusClass: req.query["statusClass"].flatMap(Int.init),
                    sinceMs: req.query["since"].flatMap(Int.init),
                    limit: Int(req.query["limit"] ?? "") ?? 100
                )
                return .json(page)
            },
            HTTPRoute("GET", "requests/{id}", annotations: .read) { req, _ in
                guard let id = req.pathParams["id"] else {
                    return .error("bad_request", "Missing request id.", status: 400)
                }
                let include = Set((req.query["include"] ?? "reqHeaders,respHeaders,reqBody,respBody")
                    .split(separator: ",").map(String.init))
                guard let detail = await store.detail(id: id, include: include) else {
                    return .error("not_found", "No captured request '\(id)'.", status: 404)
                }
                return .json(detail)
            },
            HTTPRoute("DELETE", "requests", annotations: .destructive) { _, _ in
                let cleared = await store.clear()
                return .json(["cleared": cleared])
            },
            HTTPRoute("POST", "requests/{id}/replay", annotations: .write) { req, _ in
                guard let id = req.pathParams["id"] else {
                    return .error("bad_request", "Missing request id.", status: 400)
                }
                guard let payload = await store.replayPayload(id: id) else {
                    return .error("not_found", "No captured request '\(id)'.", status: 404)
                }
                guard let url = URL(string: payload.url) else {
                    return .error("bad_request", "Captured request has no replayable URL.", status: 400)
                }
                // Optional overrides: { "headers": {…}, "body": "<base64>" }. Omitted fields keep
                // the original. Header overrides MERGE onto the captured (unredacted) headers — the
                // override value wins per key — so a console/agent only has to send the headers it
                // wants to change while the original auth is preserved automatically (the wire-facing
                // detail redacts auth, so a full-replace would force re-sending "<redacted>"). To
                // swap auth, override that one key; removing a header isn't supported (rare for replay).
                struct Overrides: Decodable { let headers: [String: String]?; let body: String? }
                let overrides = try? await req.decodeJSON(Overrides.self)
                // Case-insensitive merge: HTTP header names are case-insensitive, so an override for
                // "authorization" must WIN over a captured "Authorization" rather than producing two
                // keys (which URLRequest would then coalesce in an undefined order). Drop any original
                // key whose lowercased name collides with an override, then apply the overrides.
                let overrideHeaders = overrides?.headers ?? [:]
                let overridden = Set(overrideHeaders.keys.map { $0.lowercased() })
                var headers = payload.headers.filter { !overridden.contains($0.key.lowercased()) }
                for (key, value) in overrideHeaders { headers[key] = value }
                let body = overrides?.body.flatMap { Data(base64Encoded: $0) } ?? payload.body

                var urlReq = URLRequest(url: url)
                urlReq.httpMethod = payload.method
                urlReq.allHTTPHeaderFields = headers
                urlReq.httpBody = body

                // Record the replay as a NEW transaction, then issue it through the non-capturing
                // session (so it isn't double-recorded) and complete that same transaction.
                let newID = UUID().uuidString
                await store.begin(id: newID, method: payload.method, url: url, headers: headers, reqBody: body)
                do {
                    let (data, http) = try await SandboxURLProtocol.sendUncaptured(urlReq)
                    await store.complete(
                        id: newID, status: http?.statusCode,
                        headers: SandboxURLProtocol.normalize(http?.allHeaderFields),
                        body: data, contentType: http?.value(forHTTPHeaderField: "Content-Type")
                    )
                } catch {
                    await store.fail(id: newID, error: error)
                    return .error("replay_failed", "\(error)", status: 502)
                }
                guard let detail = await store.detail(
                    id: newID, include: ["reqHeaders", "respHeaders", "reqBody", "respBody"]
                ) else {
                    return .error("internal_error", "Replayed request vanished from the store.", status: 500)
                }
                return .json(detail)
            },
        ]
    }
}
