import Foundation

// Host apps only `import SandboxServer`; the public contract types come along for free.
#if SWIFT_PACKAGE
@_exported import SandboxServerAPI
#endif

#if DEBUG && SandboxServerEnabled
#if SWIFT_PACKAGE
import SandboxServerCore
#endif
#else
#if SWIFT_PACKAGE
import SandboxServerNoOp
#endif
#endif

/// The single public entry point of the SDK, linked into **every** build.
///
/// In a `DEBUG` build with the `SandboxServerEnabled` trait, this forwards to the real
/// `SandboxServerCore`. In any other build (Release, App Store, trait off) it forwards to
/// `SandboxServerNoOp`, whose methods do nothing — so host call sites compile and run
/// unchanged regardless of configuration, and the server is physically absent from release.
///
/// ```swift
/// SandboxServer.shared.register(NetworkPlugin())
/// Task { let result = await SandboxServer.shared.start() }
/// ```
public final class SandboxServer: @unchecked Sendable {
    public static let shared = SandboxServer()

    private let engine: any SandboxServerEngine

    private init() {
        #if DEBUG && SandboxServerEnabled
        engine = SandboxServerCore()
        #else
        engine = SandboxServerNoOp()
        #endif
    }

    /// Register a feature plugin. Call before `start()`.
    public func register(_ plugin: any SandboxPlugin) { engine.register(plugin) }

    /// Provide a typed value plugins can read via `PluginContext.hostValue` (e.g. a Core Data context).
    public func setHostValue<Value>(_ value: Value, for key: HostValueKey<Value>) {
        engine.setHostValue(value, for: key)
    }

    /// Expose an additional sandbox root (App Group / shared container) to file/db plugins.
    public func addRoot(_ url: URL) { engine.addRoot(url) }

    /// Start the embedded server. The returned `StartResult` carries the console URL
    /// (with a bootstrap token) to open in a browser — or `.disabled` in a no-op build.
    @discardableResult
    public func start(_ config: SandboxConfig = .default) async -> StartResult {
        await engine.start(config)
    }

    public func stop() async { await engine.stop() }

    public var isRunning: Bool { engine.isRunning }
}
