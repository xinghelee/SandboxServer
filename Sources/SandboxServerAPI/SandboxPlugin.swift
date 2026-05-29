import Foundation

/// Stable identifier and mount namespace for a plugin (`"fs"`, `"db"`, `"net"`, …).
public struct PluginID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let fs = PluginID("fs")
    public static let db = PluginID("db")
    public static let net = PluginID("net")
    public static let logs = PluginID("logs")
    public static let screen = PluginID("screen")
}

/// THE extension point. A type conforming to `SandboxPlugin` *is* a feature module.
/// The core composes plugins and knows nothing else about files, databases, or networking.
///
/// Routes are mounted under `/__sandbox/api/v1/<id>/`; declared `channels()` are
/// pre-registered with the WebSocket hub so the plugin can `publish` to them via its
/// `PluginContext`. `activate` is where a plugin wires capture hooks or opens resources;
/// `deactivate` must unwind them.
public protocol SandboxPlugin: Sendable {
    var id: PluginID { get }
    var capabilities: PluginCapabilities { get }

    func routes() -> [HTTPRoute]
    func channels() -> [WSChannel]
    func activate(context: any PluginContext) async throws
    func deactivate() async
}

public extension SandboxPlugin {
    func channels() -> [WSChannel] { [] }
    func activate(context: any PluginContext) async throws {}
    func deactivate() async {}
}
