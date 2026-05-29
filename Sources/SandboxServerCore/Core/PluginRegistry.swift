import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Holds registered plugins, preserves registration order, and builds the capability
/// manifest served at `GET /__sandbox/api/v1/plugins` — the single source of truth that
/// drives both the web console's panels and the MCP bridge's tool registration.
actor PluginRegistry {
    private var plugins: [PluginID: any SandboxPlugin] = [:]
    private var order: [PluginID] = []
    /// Cached routes per plugin so matching doesn't rebuild closures each request.
    private var routesByPlugin: [PluginID: [HTTPRoute]] = [:]

    func register(_ plugin: any SandboxPlugin) {
        if plugins[plugin.id] == nil { order.append(plugin.id) }
        plugins[plugin.id] = plugin
        routesByPlugin[plugin.id] = plugin.routes()
    }

    func ordered() -> [any SandboxPlugin] { order.compactMap { plugins[$0] } }

    func plugin(for id: PluginID) -> (any SandboxPlugin)? { plugins[id] }

    func routes(for id: PluginID) -> [HTTPRoute] { routesByPlugin[id] ?? [] }

    func manifest() -> [PluginCapabilities] { ordered().map(\.capabilities) }
}
