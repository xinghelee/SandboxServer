import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE in v1 (iOS/macOS). Captures `URLSessionWebSocketTask` traffic into an actor-guarded store
/// and streams it over the `ws` WebSocket channel — the WebSocket analogue of the network plugin.
final class WSPlugin: SandboxPlugin, @unchecked Sendable {
    let id = PluginID.ws
    private let store = WSStore()

    init() {}

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "WebSocket", panelKey: "ws",
            routes: ["GET connections", "GET connections/{id}", "GET connections/{id}/messages", "DELETE connections"],
            channels: [WSChannel.ws.name],
            mcpTools: [
                .init(name: "ws_list_connections", title: "List WebSocket connections",
                      description: "List captured WebSocket connections (newest first).",
                      backingMethod: "GET", backingPathSuffix: "connections", readOnlyHint: true, destructiveHint: false),
                .init(name: "ws_get_connection", title: "Get connection detail",
                      description: "Detail for one captured WebSocket connection.",
                      backingMethod: "GET", backingPathSuffix: "connections/{id}", readOnlyHint: true, destructiveHint: false),
                .init(name: "ws_list_messages", title: "List connection messages",
                      description: "Messages (sent/received) for one WebSocket connection.",
                      backingMethod: "GET", backingPathSuffix: "connections/{id}/messages", readOnlyHint: true, destructiveHint: false),
                .init(name: "ws_clear", title: "Clear captured connections",
                      description: "Discard all captured WebSocket connections.",
                      backingMethod: "DELETE", backingPathSuffix: "connections", readOnlyHint: false, destructiveHint: true),
            ],
            limitations: [
                "Captures URLSessionWebSocketTask only.",
                "Not captured: raw-socket WS libraries (Starscream, SRWebSocket) and ping/pong/close control frames.",
            ]
        )
    }

    func channels() -> [WSChannel] { [.ws] }

    func activate(context: any PluginContext) async throws {
        await store.attach(context: context)
        WebSocketSwizzler.store = store
        WebSocketSwizzler.isEnabled = true
        WebSocketSwizzler.installIfNeeded()
        context.log(WebSocketSwizzler.available
            ? "websocket capture active"
            : "websocket capture unavailable — URLSessionWebSocketTask hooks not found")
    }

    func deactivate() async {
        WebSocketSwizzler.isEnabled = false
        await store.detach()
    }

    func routes() -> [HTTPRoute] {
        let store = self.store
        return [
            HTTPRoute("GET", "connections", annotations: .read) { req, _ in
                let limit = Int(req.query["limit"] ?? "") ?? 200
                return .json(await store.listConnections(limit: limit))
            },
            HTTPRoute("GET", "connections/{id}", annotations: .read) { req, _ in
                guard let id = req.pathParams["id"] else {
                    return .error("bad_request", "Missing connection id.", status: 400)
                }
                guard let detail = await store.detail(id: id) else {
                    return .error("not_found", "No captured connection '\(id)'.", status: 404)
                }
                return .json(detail)
            },
            HTTPRoute("GET", "connections/{id}/messages", annotations: .read) { req, _ in
                guard let id = req.pathParams["id"] else {
                    return .error("bad_request", "Missing connection id.", status: 400)
                }
                let limit = Int(req.query["limit"] ?? "") ?? 500
                guard let page = await store.messagesFor(connId: id, limit: limit) else {
                    return .error("not_found", "No captured connection '\(id)'.", status: 404)
                }
                return .json(page)
            },
            HTTPRoute("DELETE", "connections", annotations: .destructive) { _, _ in
                .json(["cleared": await store.clear()])
            },
        ]
    }
}
