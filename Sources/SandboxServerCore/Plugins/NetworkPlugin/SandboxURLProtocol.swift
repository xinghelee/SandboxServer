import Foundation
import ObjectiveC

/// Associated-object key marking the SDK's own internal replay session config, so the swizzled
/// `protocolClasses` getter skips it — the definitive recursion guard.
nonisolated(unsafe) private var internalConfigMarkerKey: UInt8 = 0

/// Captures URLSession traffic by acting as a `URLProtocol`. Each intercepted request is
/// replayed through an internal session whose configuration is excluded from interception, so
/// recursion is impossible, while begin/complete are recorded into the shared `TransactionStore`.
final class SandboxURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handledKey = "com.sandboxserver.handled"

    /// Set by `NetworkPlugin.activate`. `nonisolated(unsafe)` is acceptable: assigned once at
    /// activation, read on the URL loading system's threads; `TransactionStore` is an actor.
    nonisolated(unsafe) static var store: TransactionStore?
    nonisolated(unsafe) static var isEnabled = false

    /// One shared internal session. Its configuration is tagged so the swizzled getter never
    /// injects our protocol into it — guaranteeing the replayed request is not re-intercepted.
    private static let internalSession: URLSession = {
        let config = URLSessionConfiguration.default
        objc_setAssociatedObject(config, &internalConfigMarkerKey, true, .OBJC_ASSOCIATION_RETAIN)
        config.protocolClasses = (config.protocolClasses ?? []).filter {
            ObjectIdentifier($0) != ObjectIdentifier(SandboxURLProtocol.self)
        }
        return URLSession(configuration: config)
    }()

    private let txnID = UUID().uuidString
    private var proxyTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
        guard isEnabled else { return false }
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        // URLSession converts `httpBody` into an `httpBodyStream` before the protocol sees it, so
        // a POST/PUT body would otherwise be invisible. Drain it back to Data and re-attach it to
        // the forwarded request so the body is both captured AND still sent.
        let body = Self.drainBody(from: mutable as URLRequest)
        if let body { mutable.httpBody = body }

        let store = Self.store
        let id = txnID
        let snapshot = request
        Task {
            await store?.begin(id: id, method: snapshot.httpMethod ?? "GET", url: snapshot.url,
                               headers: snapshot.allHTTPHeaderFields ?? [:], reqBody: body)
        }

        proxyTask = Self.internalSession.dataTask(with: mutable as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                Task { await store?.fail(id: id, error: error) }
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
            let http = response as? HTTPURLResponse
            Task {
                await store?.complete(
                    id: id, status: http?.statusCode,
                    headers: Self.normalize(http?.allHeaderFields),
                    body: data, contentType: http?.value(forHTTPHeaderField: "Content-Type")
                )
            }
        }
        proxyTask?.resume()
    }

    override func stopLoading() { proxyTask?.cancel() }

    /// Reads a request's body into Data: returns `httpBody` directly if set, otherwise drains
    /// `httpBodyStream` fully (it's one-shot, so the caller re-attaches the result as `httpBody`).
    /// Reads the whole body so the re-attached request is complete; `TransactionStore.begin` caps
    /// what is actually retained. Returns nil when there's no body.
    private static func drainBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufSize)
            if read < 0 { break }   // read error — keep whatever we already drained
            if read == 0 { break }  // EOF
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    /// Issues a request through the internal session whose config is excluded from interception,
    /// so the sent request is **not** re-captured. Used by `net_replay_request`. iOS 14-safe: wraps
    /// the completion-handler `dataTask` (the async `URLSession.data(for:)` API is iOS 15+).
    ///
    /// The continuation is resumed exactly once — by the completion handler, on every path. Task
    /// cancellation does not resume a checked continuation, so there's no double-resume risk; a
    /// cancelled caller simply lets the in-flight replay finish (acceptable for a one-shot replay).
    static func sendUncaptured(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        try await withCheckedThrowingContinuation { continuation in
            let task = internalSession.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (data ?? Data(), response as? HTTPURLResponse))
            }
            task.resume()
        }
    }

    static func normalize(_ headers: [AnyHashable: Any]?) -> [String: String] {
        (headers ?? [:]).reduce(into: [:]) { $0["\($1.key)"] = "\($1.value)" }
    }
}

/// Swizzles `URLSessionConfiguration.protocolClasses` so sessions created from `.default` /
/// `.ephemeral` configurations auto-include our protocol (the Wormholy/netfox technique).
/// `URLProtocol.registerClass` separately covers `URLSession.shared`.
enum ConfigurationSwizzler {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    static func installIfNeeded() {
        lock.withLock {
            guard !installed else { return }
            installed = true
            let cls: AnyClass = URLSessionConfiguration.self
            guard let original = class_getInstanceMethod(cls, #selector(getter: URLSessionConfiguration.protocolClasses)),
                  let replacement = class_getInstanceMethod(cls, #selector(URLSessionConfiguration.sandbox_protocolClasses))
            else { return }
            method_exchangeImplementations(original, replacement)
        }
    }
}

extension URLSessionConfiguration {
    @objc fileprivate func sandbox_protocolClasses() -> [AnyClass]? {
        // After the exchange, this call dispatches to the ORIGINAL implementation.
        let original = self.sandbox_protocolClasses() ?? []
        // Never inject into the SDK's own internal replay session (recursion guard).
        if objc_getAssociatedObject(self, &internalConfigMarkerKey) != nil { return original }
        let ours = ObjectIdentifier(SandboxURLProtocol.self)
        if original.contains(where: { ObjectIdentifier($0) == ours }) { return original }
        return [SandboxURLProtocol.self] + original
    }
}
