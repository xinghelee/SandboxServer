import Foundation

/// A live event channel a plugin publishes to over the single multiplexed WebSocket.
public struct WSChannel: Sendable, Hashable {
    public let name: String
    public init(_ name: String) { self.name = name }

    public static let net = WSChannel("net")
    /// Live console/log stream (the `logs` plugin publishes here).
    public static let logs = WSChannel("logs")
    public static let fs = WSChannel("fs")
    public static let db = WSChannel("db")
    /// Live captured WebSocket connections + messages (the `ws` plugin publishes here).
    public static let ws = WSChannel("ws")
}

/// A typed key for a value the host hands the SDK at registration time
/// (e.g. an `NSManagedObjectContext` for Core Data editing). Phantom-typed for safety.
public struct HostValueKey<Value>: Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

/// The handle the core injects into a plugin. It lets a plugin publish live events,
/// resolve sandbox roots, read host-supplied values, and log — *without* importing the
/// transport, the WebSocket hub, or Network.framework. This is the only way a feature
/// module touches the running server.
public protocol PluginContext: Sendable {
    /// Push an event to subscribers of `channel` over the multiplexed WebSocket.
    func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async

    /// Sandbox roots the plugin may serve: the app's own container plus any extra
    /// roots (App Group / shared containers) the host registered.
    func extraRoots() -> [URL]

    /// Roots that are present in `extraRoots()` but must be treated as read-only — writes/moves/
    /// deletes into them are refused with a clean 403 (e.g. the OS-mounted `.app` bundle). Defaults
    /// to empty so existing contexts and plugins are unaffected.
    func readOnlyRoots() -> [URL]

    /// A value the host registered under `key`, if any.
    func hostValue<Value>(_ key: HostValueKey<Value>) -> Value?

    /// The effective configuration the server started with.
    var config: SandboxConfig { get }

    /// Debug log routed through the SDK's logger (also surfaced on the `log` WS channel).
    func log(_ message: @autoclosure () -> String)
}

public extension PluginContext {
    /// Default: no read-only roots. The real core overrides this when the app bundle is exposed.
    func readOnlyRoots() -> [URL] { [] }
}
