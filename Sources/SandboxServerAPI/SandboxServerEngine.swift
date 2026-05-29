import Foundation

/// The internal seam between the public `SandboxServer` facade and an implementation.
///
/// Both the real `SandboxServerCore` and the `SandboxServerNoOp` stub conform to this,
/// which is exactly what guarantees the two products are API-compatible: the facade is
/// written once against this protocol and a CI test compiles it against both.
public protocol SandboxServerEngine: AnyObject, Sendable {
    /// Register a feature plugin. Call before `start`; registering after start activates it live.
    func register(_ plugin: any SandboxPlugin)

    /// Register a typed value the SDK should hand plugins via `PluginContext.hostValue`.
    func setHostValue<Value>(_ value: Value, for key: HostValueKey<Value>)

    /// Register an additional sandbox root (App Group / shared container) plugins may serve.
    func addRoot(_ url: URL)

    /// Start the embedded server. Idempotent: a second call returns the running info.
    func start(_ config: SandboxConfig) async -> StartResult

    /// Stop the server and deactivate plugins.
    func stop() async

    var isRunning: Bool { get }
}
