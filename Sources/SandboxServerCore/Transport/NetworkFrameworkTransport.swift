import Foundation
import Network
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// The one concrete `SocketTransport`, built on Apple's Network.framework.
///
/// Loopback binding pins `requiredLocalEndpoint` to `127.0.0.1`; `.localNetwork` listens on
/// all interfaces. Port selection tries the preferred port, then fallbacks, then an
/// OS-assigned port (0). `allowLocalEndpointReuse` avoids stale-bind failures across restarts.
final class NetworkFrameworkTransport: SocketTransport, @unchecked Sendable {
    let connections: AsyncStream<any ServerConnection>
    private let yield: AsyncStream<any ServerConnection>.Continuation
    private let queue = DispatchQueue(label: "com.sandboxserver.transport", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var counter: UInt64 = 0
    private var policy: BindingPolicy = .loopback
    private let readTimeout: TimeInterval

    init(readTimeout: TimeInterval = NWServerConnection.defaultReadTimeout) {
        self.readTimeout = readTimeout
        var continuation: AsyncStream<any ServerConnection>.Continuation!
        self.connections = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.yield = continuation
    }

    func start(policy: BindingPolicy, preferredPort: Int, fallbackPorts: [Int]) async throws -> Int {
        lock.withLock { self.policy = policy }
        let candidates = ([preferredPort] + fallbackPorts + [0]).map { max(0, $0) }
        var lastError = "unknown"
        for candidate in candidates {
            do {
                let (listener, boundPort) = try await makeListener(policy: policy, port: candidate)
                lock.withLock { self.listener = listener }
                return boundPort
            } catch {
                lastError = "\(error)"
                continue
            }
        }
        throw TransportError.listenerFailed(lastError)
    }

    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
        }
        yield.finish()
    }

    private func makeListener(policy: BindingPolicy, port: Int) async throws -> (NWListener, Int) {
        // Bind the port normally (reliable). Loopback-only enforcement happens at accept time by
        // rejecting non-loopback peers — `requiredLocalEndpoint`/`requiredInterfaceType` on an
        // NWListener are unreliable for pinning to 127.0.0.1.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? .any

        let listener = try NWListener(using: params, on: nwPort)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(NWListener, Int), Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let bound = Int(listener.port?.rawValue ?? 0)
                    if resumed.fire() { cont.resume(returning: (listener, bound)) }
                case .failed(let error), .waiting(let error):
                    // `.waiting` here means the port is unavailable (e.g. EADDRINUSE); fail so the
                    // caller tries the next candidate. The final candidate (port 0) always succeeds.
                    listener.cancel()
                    if resumed.fire() { cont.resume(throwing: TransportError.listenerFailed("\(error)")) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        let policy = lock.withLock { self.policy }
        if policy == .loopback, !Self.isLoopback(connection.endpoint) {
            connection.cancel() // reject LAN peers when bound for loopback-only use
            return
        }
        let id: UInt64 = lock.withLock { counter += 1; return counter }
        let wrapped = NWServerConnection(connection: connection, id: id, queue: queue, readTimeout: readTimeout)
        connection.start(queue: queue)
        yield.yield(wrapped)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let v4): return v4.isLoopback
        case .ipv6(let v6): return v6.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}

/// Wraps a single `NWConnection` as an async byte stream. `receive()` re-issues until it has
/// bytes or hits EOF, so callers never see spurious empty reads.
private enum ConnectionReadError: Error { case timedOut }

final class NWServerConnection: ServerConnection, @unchecked Sendable {
    let id: UInt64
    private let connection: NWConnection
    private let queue: DispatchQueue

    /// Idle read timeout for the HTTP request phase: a peer that opens a connection (or promises a
    /// body) then sends nothing must not pin this read task forever. The WS hub clears it for the
    /// long-lived frame loop (which is legitimately idle between events) via `setReadTimeout(nil)`.
    static let defaultReadTimeout: TimeInterval = 30
    private let timeoutLock = NSLock()
    private var readTimeout: TimeInterval?

    init(connection: NWConnection, id: UInt64, queue: DispatchQueue, readTimeout: TimeInterval = NWServerConnection.defaultReadTimeout) {
        self.connection = connection
        self.id = id
        self.queue = queue
        self.readTimeout = readTimeout
    }

    func setReadTimeout(_ seconds: TimeInterval?) {
        timeoutLock.withLock { readTimeout = seconds }
    }

    func receive() async throws -> [UInt8]? {
        // `[]` is the "nothing yet, not closed" sentinel; loop until real bytes or EOF.
        while true {
            let timeout = timeoutLock.withLock { readTimeout }
            let result: [UInt8]? = try await withCheckedThrowingContinuation { cont in
                // `ResumeOnce` makes the timeout work item and the receive callback mutually
                // exclusive, so the continuation resumes exactly once even under their race.
                let once = ResumeOnce()
                // Reference-typed and only cancel()'d (thread-safe); the capture is benign.
                nonisolated(unsafe) let timeoutItem: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem { [weak self] in
                        guard once.fire() else { return }
                        self?.connection.cancel() // also fires the receive callback below (a no-op via `once`)
                        cont.resume(throwing: ConnectionReadError.timedOut)
                    }
                    timeoutItem = item
                    queue.asyncAfter(deadline: .now() + timeout, execute: item)
                } else {
                    timeoutItem = nil
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    guard once.fire() else { return }
                    // A completed read cancels its own timer here, so no timer ever outlives the
                    // receive() that armed it — nothing is left pending once readHead/readBody return.
                    timeoutItem?.cancel()
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: [UInt8](data))
                    } else if isComplete {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: [])
                    }
                }
            }
            guard let bytes = result else { return nil }
            if bytes.isEmpty { continue }
            return bytes
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            })
        }
    }

    func close() { connection.cancel() }
}

/// Tiny helper guaranteeing a continuation resumes exactly once across Network.framework's
/// multiple state callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
