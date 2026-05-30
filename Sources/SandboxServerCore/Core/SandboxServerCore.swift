import Foundation
#if canImport(Darwin)
import Darwin // sysctlbyname for the hardware model identifier
#endif
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The concrete engine assembled when the SDK is enabled. It wires transport + router +
/// middleware + WebSocket hub + plugin registry, runs the accept loop, enforces the
/// `ReleaseGuard`, mints the session token, logs the safety banner, and (in `.localNetwork`)
/// advertises Bonjour. It owns nothing feature-specific — files/db/network arrive as plugins.
public final class SandboxServerCore: SandboxServerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingPlugins: [any SandboxPlugin] = []
    private var hostValues: [String: Any] = [:]
    private var roots: [URL] = []
    private var runtime: Runtime?
    private var acceptTask: Task<Void, Never>?
    private let bonjour = BonjourAdvertiser()
    private var lifecycleObserver: NSObjectProtocol?

    private let logger: @Sendable (String) -> Void = { msg in
        let line = "[SandboxServer] \(msg)"
        print(line)
        // When console capture is mirroring stdout it will pick this line up; emitting here too
        // would duplicate it. Otherwise, surface the SDK's own logs directly in the logs stream.
        if !ConsoleCapture.shared.isActive {
            LogStore.shared.emit(level: guessLogLevel(line), message: line, source: "sdk")
        }
    }

    public init() {}

    /// Everything created by a successful `start`, captured immutably and shared with the accept loop.
    private struct Runtime: Sendable {
        let transport: NetworkFrameworkTransport
        let registry: PluginRegistry
        let hub: WSHub
        let middleware: MiddlewareChain
        let staticConsole: StaticConsole
        let context: CorePluginContext
        let info: StartInfo
    }

    public var isRunning: Bool { lock.withLock { runtime != nil } }

    public func register(_ plugin: any SandboxPlugin) {
        let live = lock.withLock { () -> Runtime? in pendingPlugins.append(plugin); return runtime }
        if let live {
            Task { await live.registry.register(plugin); try? await plugin.activate(context: live.context) }
        }
    }

    public func setHostValue<Value>(_ value: Value, for key: HostValueKey<Value>) {
        lock.withLock { hostValues[key.name] = value }
    }

    public func addRoot(_ url: URL) { lock.withLock { roots.append(url) } }

    public func log(_ message: String, level: String = "info", category: String? = nil) {
        LogStore.shared.emit(level: level, message: message, source: "app", category: category)
    }

    public func start(_ config: SandboxConfig) async -> StartResult {
        if let existing = lock.withLock({ self.runtime }) { return .started(existing.info) }

        switch ReleaseGuard.verify() {
        case .refused(let reason):
            logger("⚠️ \(reason). Not starting.")
            return .failed(reason: reason)
        case .allowed:
            break
        }

        var cfg = config
        if cfg.auth == .none, cfg.bindingPolicy == .localNetwork {
            logger("⚠️ auth=.none is not allowed on .localNetwork; forcing a session token.")
            cfg.auth = .token
        }

        let (plugins, snapshotRoots, snapshotValues) = lock.withLock {
            (pendingPlugins, roots, hostValues)
        }

        let auth = AuthGate(mode: cfg.auth)
        let registry = PluginRegistry()
        let hub = WSHub(log: logger)
        let transport = NetworkFrameworkTransport(readTimeout: cfg.requestReadTimeout)
        let staticConsole = StaticConsole(webRoot: ResourceBundle.webRoot)
        let context = CorePluginContext(
            config: cfg, hub: hub, roots: snapshotRoots, hostValues: snapshotValues, logger: logger
        )

        var allPlugins: [any SandboxPlugin] = []
        if cfg.builtInPlugins.contains(.network) { allPlugins.append(NetworkPlugin()) }
        if cfg.builtInPlugins.contains(.files) { allPlugins.append(FilePlugin()) }
        if cfg.builtInPlugins.contains(.database) { allPlugins.append(DBPlugin()) }
        if cfg.builtInPlugins.contains(.logs) { allPlugins.append(LogPlugin()) }
        if cfg.builtInPlugins.contains(.screen) { allPlugins.append(ScreenPlugin()) }
        if cfg.builtInPlugins.contains(.hierarchy) { allPlugins.append(HierarchyPlugin()) }
        if cfg.builtInPlugins.contains(.websocket) { allPlugins.append(WSPlugin()) }
        allPlugins.append(contentsOf: plugins) // host-registered custom plugins

        for plugin in allPlugins {
            await registry.register(plugin)
            do { try await plugin.activate(context: context) }
            catch { logger("plugin \(plugin.id) failed to activate: \(error)") }
        }

        let port: Int
        do {
            port = try await transport.start(
                policy: cfg.bindingPolicy, preferredPort: cfg.preferredPort, fallbackPorts: cfg.fallbackPorts
            )
        } catch {
            logger("failed to bind a port: \(error)")
            return .failed(reason: "\(error)")
        }

        let info = makeStartInfo(port: port, policy: cfg.bindingPolicy, token: auth.token)
        let middleware = MiddlewareChain(auth: auth, bindingPolicy: cfg.bindingPolicy)
        let built = Runtime(
            transport: transport, registry: registry, hub: hub,
            middleware: middleware, staticConsole: staticConsole, context: context, info: info
        )
        lock.withLock { self.runtime = built }

        acceptTask = Task { [weak self] in
            for await connection in transport.connections {
                Task { await self?.handle(connection, runtime: built) }
            }
        }

        if cfg.bindingPolicy == .localNetwork {
            bonjour.start(port: port, name: cfg.serviceName ?? defaultServiceName(), txt: [
                "ver": "1", "apiVersion": "1",
                "deviceName": deviceName(), "appBundleId": appBundleID(),
                "requiresAuth": cfg.auth == .token ? "true" : "false",
            ])
        }
        observeLifecycle()
        logBanner(info: info, config: cfg)
        return .started(info)
    }

    public func stop() async {
        let captured: Runtime? = lock.withLock { let r = runtime; runtime = nil; return r }
        acceptTask?.cancel(); acceptTask = nil
        bonjour.stop()
        if let observer = lifecycleObserver { NotificationCenter.default.removeObserver(observer) }
        guard let captured else { return }
        captured.transport.stop()
        for plugin in await captured.registry.ordered() { await plugin.deactivate() }
        logger("stopped.")
    }

    // MARK: - Connection handling

    private func handle(_ connection: any ServerConnection, runtime: Runtime) async {
        let reader = HTTPConnectionReader(connection)
        do {
            guard let head = try await reader.readHead() else { connection.close(); return }

            if head.path == Router.wsPath {
                await handleWebSocketUpgrade(head, reader: reader, connection: connection, runtime: runtime)
                return // the hub owns this connection now; do not close
            }

            let response = await route(head: head, reader: reader, runtime: runtime)
            try await HTTPResponseWriter.write(response, to: connection, closeAfter: true)
        } catch {
            // best effort; fall through to close
        }
        connection.close()
    }

    private func handleWebSocketUpgrade(
        _ head: HTTPRequestHead, reader: HTTPConnectionReader,
        connection: any ServerConnection, runtime: Runtime
    ) async {
        if !head.isWebSocketUpgrade {
            try? await HTTPResponseWriter.write(.error("bad_request", "Not a WebSocket upgrade.", status: 400),
                                                to: connection, closeAfter: true)
            connection.close(); return
        }
        if let rejection = runtime.middleware.reject(head, requiresAuth: true) {
            try? await HTTPResponseWriter.write(rejection, to: connection, closeAfter: true)
            connection.close(); return
        }
        guard let key = head.header("sec-websocket-key") else {
            try? await HTTPResponseWriter.write(.error("bad_request", "Missing Sec-WebSocket-Key.", status: 400),
                                                to: connection, closeAfter: true)
            connection.close(); return
        }
        let handshake = WebSocketCodec.handshakeResponse(acceptKey: WebSocketCodec.acceptKey(for: key))
        do { try await connection.send(handshake) } catch { connection.close(); return }
        // The WS frame loop is legitimately idle between events — drop the HTTP-phase read timeout
        // so the hub doesn't tear down a quiet but healthy subscriber.
        connection.setReadTimeout(nil)
        let leftover = reader.leftover
        Task { await runtime.hub.serve(connection, leftover: leftover) }
    }

    private func route(head: HTTPRequestHead, reader: HTTPConnectionReader, runtime: Runtime) async -> SBResponse {
        let path = head.path

        // Static console — served without a token so the browser can bootstrap from ?token=.
        if !path.hasPrefix("/__sandbox") {
            if let rejection = runtime.middleware.reject(head, requiresAuth: false) { return rejection }
            return runtime.staticConsole.serve(path: path)
        }

        guard path.hasPrefix(Router.apiPrefix) else {
            return .error("not_found", "Unknown path '\(path)'.", status: 404)
        }
        if let rejection = runtime.middleware.reject(head, requiresAuth: true) { return rejection }

        let apiPath = String(path.dropFirst(Router.apiPrefix.count)).drop(while: { $0 == "/" })

        if apiPath == "healthz" { return healthResponse(runtime: runtime) }
        if apiPath == "plugins" { return await pluginsResponse(runtime: runtime) }

        let parts = apiPath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else {
            return .error("not_found", "No plugin in path.", status: 404)
        }
        let pluginID = PluginID(String(first))
        guard (await runtime.registry.plugin(for: pluginID)) != nil else {
            return .error("not_found", "No plugin '\(pluginID)'.", status: 404)
        }
        let suffix = parts.count > 1 ? String(parts[1]) : ""
        let routes = await runtime.registry.routes(for: pluginID)
        guard let match = Router.match(method: head.method, suffix: suffix, routes: routes) else {
            return .error("not_found", "No route for \(head.method) \(suffix).", status: 404)
        }

        let bodyData: Data
        do {
            bodyData = try await reader.readBody(length: head.contentLength)
        } catch HTTPError.payloadTooLarge {
            return .error("payload_too_large",
                          "Request body exceeds the \(HTTPConnectionReader.maxBodyBytes / (1024 * 1024)) MiB limit.",
                          status: 413)
        } catch {
            return .error("bad_request", "Could not read the request body.", status: 400)
        }
        let request = SBRequest(
            method: head.method, path: suffix, pathParams: match.params,
            query: head.query, headers: head.headers, range: head.byteRange,
            body: { Self.dataStream(bodyData) }
        )
        do { return try await match.route.handler(request, runtime.context) }
        catch { return .error("handler_error", "\(error)", status: 500) }
    }

    // MARK: - Meta endpoints

    private struct HealthDTO: Encodable {
        let apiVersion = "1"
        let buildConfig: String
        let deviceName: String
        let appBundleId: String
        let bindingPolicy: String
        let requiresAuth: Bool
        // Richer host/app identity — additive; nil fields are omitted, consumers ignore unknowns.
        let appName: String?
        let appVersion: String?
        let appBuild: String?
        let sdkVersion: String
        let osName: String
        let osVersion: String
        let deviceModel: String?
        let appIcon: String? // base64 PNG (iOS only)
    }

    private func healthResponse(runtime: Runtime) -> SBResponse {
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let info = Bundle.main.infoDictionary
        return .json(HealthDTO(
            buildConfig: build,
            deviceName: deviceName(),
            appBundleId: appBundleID(),
            bindingPolicy: runtime.info.bindingPolicy == .loopback ? "loopback" : "localNetwork",
            requiresAuth: runtime.middleware.auth.mode == .token,
            appName: (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String),
            appVersion: info?["CFBundleShortVersionString"] as? String,
            appBuild: info?["CFBundleVersion"] as? String,
            sdkVersion: Self.sdkVersion,
            osName: osName(),
            osVersion: osVersionString(),
            deviceModel: deviceModelIdentifier(),
            appIcon: appIconBase64()
        ))
    }

    private func pluginsResponse(runtime: Runtime) async -> SBResponse {
        .json(Page(items: await runtime.registry.manifest()))
    }

    // MARK: - Helpers

    private static func dataStream(_ data: Data) -> AsyncThrowingStream<ArraySlice<UInt8>, Error> {
        AsyncThrowingStream { continuation in
            if !data.isEmpty { continuation.yield(ArraySlice([UInt8](data))) }
            continuation.finish()
        }
    }

    private func makeStartInfo(port: Int, policy: BindingPolicy, token: String?) -> StartInfo {
        let host = policy == .loopback ? "127.0.0.1" : (localIPAddress() ?? "0.0.0.0")
        let base = "http://\(host):\(port)"
        let consoleString = token.map { "\(base)/?token=\($0)" } ?? "\(base)/"
        return StartInfo(
            consoleURL: URL(string: consoleString) ?? URL(string: base)!,
            apiBaseURL: URL(string: "\(base)\(Router.apiPrefix)")!,
            port: port, bindingPolicy: policy, token: token
        )
    }

    private func logBanner(info: StartInfo, config: SandboxConfig) {
        #if DEBUG
        let build = "DEBUG"
        #else
        let build = "RELEASE"
        #endif
        var lines = [
            "──────────── SandboxServer ────────────",
            "build:    \(build)",
            "binding:  \(config.bindingPolicy == .loopback ? "loopback (127.0.0.1)" : "localNetwork (all interfaces)")",
            "console:  \(info.consoleURL.absoluteString)",
        ]
        if let token = info.token { lines.append("token:    \(token)") }
        if config.bindingPolicy == .localNetwork {
            lines.append("⚠️ reachable by ANY device on this network — use the token and a trusted Wi-Fi.")
        }
        lines.append("───────────────────────────────────────")
        logger("\n" + lines.joined(separator: "\n"))
    }

    private func observeLifecycle() {
        #if canImport(UIKit)
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.logger("app became active.")
        }
        #endif
    }

    private func deviceName() -> String {
        // `UIDevice.current.name` is main-actor-isolated; `hostName` is a safe, non-isolated
        // stand-in that works on every platform (this value is purely informational).
        ProcessInfo.processInfo.hostName
    }

    private func appBundleID() -> String { Bundle.main.bundleIdentifier ?? "unknown" }

    static let sdkVersion = "0.1.0"

    private func osName() -> String {
        #if os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "OS"
        #endif
    }

    private func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Hardware model identifier, e.g. "iPhone16,1". Prefers the Simulator's env override; falls back
    /// to the `hw.machine` sysctl. Non-isolated (avoids the main-actor `UIDevice.current`).
    private func deviceModelIdentifier() -> String? {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty {
            return sim
        }
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        #else
        return nil
        #endif
    }

    /// The app's primary icon as a base64 PNG (iOS only; the icon lives in the app bundle).
    private func appIconBase64() -> String? {
        #if canImport(UIKit)
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last,
              let image = UIImage(named: name),
              let png = image.pngData() else { return nil }
        return png.base64EncodedString()
        #else
        return nil
        #endif
    }

    private func defaultServiceName() -> String { "SandboxServer @ \(deviceName())" }

    private func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) else { continue }
            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }
            guard strcmp(ptr.pointee.ifa_name, "en0") == 0 else { continue } // Wi-Fi
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return address
    }
}

/// The handle the core injects into every plugin. Lets a plugin publish WS events, read
/// host-provided values, resolve roots, and log — without importing the transport or hub.
final class CorePluginContext: PluginContext, @unchecked Sendable {
    let config: SandboxConfig
    private let hub: WSHub
    private let roots: [URL]
    private let hostValues: [String: Any]
    private let logger: @Sendable (String) -> Void

    init(config: SandboxConfig, hub: WSHub, roots: [URL], hostValues: [String: Any],
         logger: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.hub = hub
        self.roots = roots
        self.hostValues = hostValues
        self.logger = logger
    }

    func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {
        await hub.publish(channel: channel, type: type, payload: payload)
    }

    func extraRoots() -> [URL] { roots }

    func hostValue<Value>(_ key: HostValueKey<Value>) -> Value? { hostValues[key.name] as? Value }

    func log(_ message: @autoclosure () -> String) { logger(message()) }
}
