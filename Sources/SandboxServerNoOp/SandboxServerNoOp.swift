import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// The implementation linked into Release / disabled builds. Every method is inert.
///
/// It mirrors the full public API so the facade compiles identically against it, and it
/// carries no transport, no plugins, and no web assets — guaranteeing the server is
/// physically absent from a shipping build. `start` logs a single one-line notice.
public final class SandboxServerNoOp: SandboxServerEngine, @unchecked Sendable {
    public init() {}

    public func register(_ plugin: any SandboxPlugin) {}
    public func setHostValue<Value>(_ value: Value, for key: HostValueKey<Value>) {}
    public func addRoot(_ url: URL) {}

    public func start(_ config: SandboxConfig) async -> StartResult {
        _ = Self.noticeOnce
        return .disabled
    }

    public func stop() async {}

    public func log(_ message: String, level: String = "info", category: String? = nil) {}

    public var isRunning: Bool { false }

    private static let noticeOnce: Void = {
        print("[SandboxServer] disabled in this build (no-op product). The debug server is not running.")
    }()
}
