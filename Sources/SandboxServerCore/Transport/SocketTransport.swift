import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Abstraction over the listening socket and the byte-stream connections it accepts.
///
/// The one concrete conformer is `NetworkFrameworkTransport`. Everything above this seam
/// (HTTP parsing, routing, the WebSocket hub, plugins) is transport-agnostic, which is what
/// keeps a vendored fallback (e.g. FlyingFox for the socket layer only) a drop-in option.
protocol SocketTransport: Sendable {
    /// Binds and starts listening, trying `preferredPort` then `fallbackPorts` then an
    /// OS-assigned port. Returns the port actually bound.
    func start(policy: BindingPolicy, preferredPort: Int, fallbackPorts: [Int]) async throws -> Int

    /// A stream of accepted, started connections.
    var connections: AsyncStream<any ServerConnection> { get }

    func stop()
}

/// A single accepted connection, surfaced as an async byte stream.
protocol ServerConnection: AnyObject, Sendable {
    var id: UInt64 { get }
    /// The next non-empty chunk of received bytes, or `nil` at EOF.
    func receive() async throws -> [UInt8]?
    func send(_ bytes: [UInt8]) async throws
    func close()
    /// Idle read timeout in seconds, or `nil` to disable. The HTTP request phase keeps a default
    /// so a half-open peer can't pin the read task; the long-lived WebSocket loop disables it.
    func setReadTimeout(_ seconds: TimeInterval?)
}

extension ServerConnection {
    /// Default no-op for transports (and test doubles) without an idle timeout.
    func setReadTimeout(_ seconds: TimeInterval?) {}
}

enum TransportError: Error, CustomStringConvertible {
    case noAvailablePort
    case listenerFailed(String)

    var description: String {
        switch self {
        case .noAvailablePort: return "No available port to bind."
        case .listenerFailed(let m): return "Listener failed: \(m)"
        }
    }
}
