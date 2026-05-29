import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE in v1. Captures URLSession traffic into an actor-guarded ring buffer and streams it
/// over the `net` WebSocket channel, so the whole transport → plugin → console → MCP stack is
/// exercised end-to-end on day one. Replay is stubbed for v2.
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
                      description: "Re-issue a captured request, optionally with overrides (v2).",
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
            HTTPRoute("POST", "requests/{id}/replay", annotations: .write) { _, _ in
                .notImplemented("Replay arrives in v2.")
            },
        ]
    }
}
