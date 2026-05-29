import Foundation

/// A plugin's declared intent to back one MCP tool. The MCP bridge registers exactly
/// one tool per descriptor, reading the manifest at `GET /__sandbox/api/v1/plugins`.
public struct MCPToolDescriptor: Codable, Sendable {
    /// snake_case tool name, e.g. `"net_list_requests"`.
    public let name: String
    public let title: String
    public let description: String
    /// HTTP method of the device endpoint that backs this tool.
    public let backingMethod: String
    /// Path suffix (relative to the plugin prefix) of the backing endpoint, e.g. `"requests/{id}"`.
    public let backingPathSuffix: String
    public let readOnlyHint: Bool
    public let destructiveHint: Bool

    public init(
        name: String, title: String, description: String,
        backingMethod: String, backingPathSuffix: String,
        readOnlyHint: Bool, destructiveHint: Bool
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.backingMethod = backingMethod
        self.backingPathSuffix = backingPathSuffix
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
    }
}

/// What a plugin self-reports. This single manifest drives BOTH the web console
/// (which built-in panel to render, keyed on `panelKey`) and MCP tool registration.
public struct PluginCapabilities: Codable, Sendable {
    public let id: String
    public let version: String
    public let title: String
    /// Identifies the built-in console panel that renders this plugin (e.g. `"files"`).
    public let panelKey: String
    /// Human-readable list of mounted routes, for display.
    public let routes: [String]
    /// WS channel names this plugin publishes to.
    public let channels: [String]
    public let mcpTools: [MCPToolDescriptor]

    public init(
        id: String, version: String, title: String, panelKey: String,
        routes: [String] = [], channels: [String] = [], mcpTools: [MCPToolDescriptor] = []
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.panelKey = panelKey
        self.routes = routes
        self.channels = channels
        self.mcpTools = mcpTools
    }
}
