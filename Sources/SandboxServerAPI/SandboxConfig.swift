import Foundation

/// How the embedded server binds its listening socket.
///
/// There is deliberately no boolean toggle: exposing the server on the LAN is a
/// distinct, named, loudly-logged choice — never an accidental fallback.
public enum BindingPolicy: Sendable, Equatable {
    /// `127.0.0.1` only. The default. Automatically safe and all the Simulator needs.
    case loopback
    /// Binds all interfaces so a browser/MCP client on the same Wi-Fi can reach a
    /// physical device. Opt-in only; the core logs a loud warning when this is used.
    case localNetwork
}

/// Authentication enforced by the transport middleware *before* any plugin runs.
public enum AuthMode: Sendable, Equatable {
    /// A fresh per-session bearer token is required on every request and WS upgrade.
    /// Recommended whenever the server is reachable by anything other than this device;
    /// automatically forced under `.localNetwork`.
    case token
    /// No token — the default. Under `.loopback` (the default binding) the server is only
    /// reachable from this device, so requiring a per-launch token just forces you to
    /// re-open the console on every restart. Auto-upgraded to `.token` under `.localNetwork`.
    case none
}

/// Which built-in feature plugins the core auto-registers on `start()`. The host never names
/// the plugin types directly (they don't exist in a no-op build) — it just opts in here.
public struct BuiltInPlugins: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let network  = BuiltInPlugins(rawValue: 1 << 0)
    public static let files    = BuiltInPlugins(rawValue: 1 << 1)
    public static let database = BuiltInPlugins(rawValue: 1 << 2)
    public static let logs     = BuiltInPlugins(rawValue: 1 << 3)
    /// Live screen mirror + semantic tap (iOS only; a no-op on other platforms).
    public static let screen   = BuiltInPlugins(rawValue: 1 << 4)
    /// Live view-hierarchy tree for the 3D layer inspector (iOS only).
    public static let hierarchy = BuiltInPlugins(rawValue: 1 << 5)
    /// Live capture of the app's URLSessionWebSocketTask traffic.
    public static let websocket = BuiltInPlugins(rawValue: 1 << 6)

    public static let all: BuiltInPlugins = [.network, .files, .database, .logs, .screen, .hierarchy, .websocket]
    public static let none: BuiltInPlugins = []
}

/// Everything the host can tune when starting the server. All fields have safe defaults.
public struct SandboxConfig: Sendable {
    public var bindingPolicy: BindingPolicy
    public var auth: AuthMode
    public var builtInPlugins: BuiltInPlugins
    /// First port the listener tries.
    public var preferredPort: Int
    /// Tried in order if `preferredPort` is taken; an OS-assigned port (0) is the final fallback.
    public var fallbackPorts: [Int]
    /// Bonjour service name advertised under `_sandboxserver._tcp` (`.localNetwork` only).
    /// `nil` derives a name from the device.
    public var serviceName: String?
    /// Request/response header names redacted at write-time by capturing plugins,
    /// in addition to the always-on defaults (Authorization, Cookie, Set-Cookie, …).
    public var extraRedactedHeaders: [String]
    /// When `true`, the `logs` plugin tees the process's `stdout`/`stderr` (capturing
    /// `print`, `NSLog`, and anything written to fd 1/2) into the live log stream while
    /// still forwarding the bytes to the original console. Off by default — opt in to
    /// mirror raw console output; the SDK's own logs and `SandboxServer.log(_:)` are
    /// always captured regardless.
    public var captureConsole: Bool

    public init(
        bindingPolicy: BindingPolicy = .loopback,
        auth: AuthMode = .none,
        builtInPlugins: BuiltInPlugins = .all,
        preferredPort: Int = 8080,
        fallbackPorts: [Int] = [8081, 8082, 8090, 9090],
        serviceName: String? = nil,
        extraRedactedHeaders: [String] = [],
        captureConsole: Bool = false
    ) {
        self.bindingPolicy = bindingPolicy
        self.auth = auth
        self.builtInPlugins = builtInPlugins
        self.preferredPort = preferredPort
        self.fallbackPorts = fallbackPorts
        self.serviceName = serviceName
        self.extraRedactedHeaders = extraRedactedHeaders
        self.captureConsole = captureConsole
    }

    public static var `default`: SandboxConfig { SandboxConfig() }
}

/// What the host gets back from `start(...)`.
public enum StartResult: Sendable {
    /// The server is live. `StartInfo` carries the console URL (with bootstrap token) to open.
    case started(StartInfo)
    /// This build links the no-op product (Release / SandboxServer disabled). Nothing happened.
    case disabled
    /// The server refused or failed to start (e.g. ReleaseGuard tripped, no usable port).
    case failed(reason: String)
}

public struct StartInfo: Sendable {
    /// The base URL of the console, e.g. `http://127.0.0.1:8080/?token=…`. Open this in a browser.
    public let consoleURL: URL
    /// The base URL of the REST API root (`…/__sandbox/api/v1`).
    public let apiBaseURL: URL
    public let port: Int
    public let bindingPolicy: BindingPolicy
    /// The per-session bearer token, or `nil` when `auth == .none`.
    public let token: String?

    public init(consoleURL: URL, apiBaseURL: URL, port: Int, bindingPolicy: BindingPolicy, token: String?) {
        self.consoleURL = consoleURL
        self.apiBaseURL = apiBaseURL
        self.port = port
        self.bindingPolicy = bindingPolicy
        self.token = token
    }
}
