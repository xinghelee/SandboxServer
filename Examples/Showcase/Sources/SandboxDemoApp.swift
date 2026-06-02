import SwiftUI
import UIKit
import UserNotifications
import SQLite3
import SandboxServerCore
import SandboxServerAPI

// SQLite wants this for TEXT binds that it should copy (the Swift String is transient).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Toy symmetric "encryption" (XOR with a fixed key) standing in for whatever real envelope a host
/// app uses. The point of the demo: the key lives in the app, never in the debug tool — the
/// `networkBodyDecoder` calls back into here to render bodies, but the console only sees the result.
enum DemoCrypto {
    private static let key = Array("sandbox-demo-key".utf8)
    /// XOR is its own inverse, so this both "encrypts" and "decrypts".
    static func xor(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return Data(data.enumerated().map { $0.element ^ key[$0.offset % key.count] })
    }
}

@main
struct SandboxDemoApp: App {
    // A classic AppDelegate so the notify plugin's `notify_simulate_remote` has a real
    // `didReceiveRemoteNotification` to call (a SwiftUI lifecycle app has none by default).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ServerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.start() }
        }
    }
}

/// Minimal app delegate that exists to demonstrate the `notify` plugin end-to-end:
/// - `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` is the handler the
///   plugin's `notify_simulate_remote` / `POST /notify/remote` invokes in-process. With it
///   implemented, the console reports `delivered: true` instead of "no handler".
/// - As `UNUserNotificationCenterDelegate`, `willPresent` lets local notifications fired via
///   `notify_send_local` show as a banner even while the app is in the foreground.
///
/// The demo enables `captureConsole`, so the `print` lines below surface live in the Logs panel —
/// that's the visible proof a simulated push was actually handled by the app.
final class AppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let aps = userInfo["aps"] as? [String: Any]
        print("[Demo] 📩 didReceiveRemoteNotification handled — aps=\(aps ?? [:]), keys=\(Array(userInfo.keys))")
        // A silent data push draws no system UI, so show a visible alert in the demo to prove the
        // simulated push reached the app (also visible through the Screen mirror in the console).
        Self.presentPushAlert(userInfo: userInfo, aps: aps)
        completionHandler(.newData)
    }

    /// Pops a `UIAlertController` describing the received push, on the top-most view controller.
    private static func presentPushAlert(userInfo: [AnyHashable: Any], aps: [String: Any]?) {
        var title = "Remote push"
        var message = ""
        if let alert = aps?["alert"] as? String {
            message = alert
        } else if let alert = aps?["alert"] as? [String: Any] {
            title = (alert["title"] as? String) ?? title
            message = (alert["body"] as? String) ?? (alert["subtitle"] as? String) ?? ""
        }
        if message.isEmpty {
            let keys = userInfo.keys.map { "\($0)" }.sorted().joined(separator: ", ")
            message = "payload keys: \(keys)"
        }
        guard let top = topViewController() else { return }
        let ac = UIAlertController(title: "📩 \(title)", message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(ac, animated: true)
    }

    /// The front-most view controller of the key window (so the alert is presented above whatever
    /// SwiftUI content — or an already-presented sheet — is currently on screen).
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // Show banners for foreground local notifications so `notify_send_local` is visibly delivered.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("[Demo] 🔔 willPresent local notification: \(notification.request.content.title)")
        completionHandler([.banner, .list, .sound, .badge])
    }

    // Log taps on a delivered notification (so the full local-notification round-trip is observable).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        print("[Demo] 👆 notification tapped: \(response.notification.request.identifier)")
        completionHandler()
    }
}

/// Boots the embedded debug server and seeds a generous, varied dataset so every console panel —
/// and the newer features (network virtualization + replay, big-DB table list, suffix Range) —
/// has realistic volume to exercise. All seed traffic is local-loopback, so it works offline.
@MainActor
final class ServerModel: ObservableObject {
    enum State { case starting, running, disabled, failed(String) }

    @Published var state: State = .starting
    @Published var consoleURL: String = ""
    @Published var token: String = ""
    @Published var requestCount: Int = 0
    @Published var lastRequest: String = "—"
    @Published var logCount: Int = 0
    @Published var tapCount: Int = 0
    @Published var demoText: String = ""

    private let server = SandboxServerCore()
    private var apiBase: URL?
    private var authToken: String?

    func start() async {
        #if DEBUG
        // LAN mode lets another browser/MCP client on the same trusted Wi-Fi reach the demo.
        // Token validation is off by default, including local-network binding; opt into
        // auth: .token if you need credentials on the LAN.
        // captureConsole mirrors print/NSLog into the Logs panel; SandboxServer.log adds structured lines.
        var config = SandboxConfig(bindingPolicy: .localNetwork, captureConsole: true)
        // Demo of the display-only body decoder: this app "encrypts" some bodies at the app layer
        // (DemoCrypto, a toy XOR). The hook renders them as readable JSON in the Network panel/MCP,
        // while the request on the wire still carries the ciphertext and replay re-sends it verbatim.
        config.networkBodyDecoder = { body in
            guard body.headers.contains(where: { $0.key.caseInsensitiveCompare("X-Demo-Encrypted") == .orderedSame }),
                  let clear = DemoCrypto.xor(body.body),
                  let json = String(data: clear, encoding: .utf8) else { return nil }
            return "🔓 decoded by host hook (demo XOR):\n\(json)"
        }
        let result = await server.start(config)
        switch result {
        case .started(let info):
            consoleURL = info.consoleURL.absoluteString
            token = info.token ?? "(none)"
            apiBase = info.apiBaseURL
            authToken = info.token
            state = .running
            Self.seedSandbox()   // files of varied sizes (incl. a large one for Range testing)
            Self.seedDatabase()  // a multi-table DB with one big table (cheap-counts + grid virtualization)
            Self.seedDefaults()  // varied, typed UserDefaults so the Defaults panel/MCP has content
            seedLogs(250)        // a few hundred log lines + a live heartbeat
            fireLocalBatch(150)  // a few hundred captured requests (net virtualization + replay)
            fireSampleRequest()  // a few real external requests too, best-effort
            fireEncryptedRequest()  // one app-layer-"encrypted" body, decoded only in the console
            openWebSocket()      // a live WebSocket so the WebSocket panel has traffic
        case .disabled:
            state = .disabled
        case .failed(let reason):
            state = .failed(reason)
        }
        #else
        state = .disabled
        #endif
    }

    // MARK: - Files

    /// Writes sample files into Documents, including a ~250 KB file so you can exercise HTTP Range
    /// (e.g. `curl -r -512 '…/fs/file?path=…/data/large.log'` for the last 512 bytes).
    private static func seedSandbox() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? fm.createDirectory(at: docs.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: docs.appendingPathComponent("data"), withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("welcome.json", "{\n  \"app\": \"SandboxServer Demo\",\n  \"sandbox\": true,\n  \"editable\": true\n}\n"),
            ("notes.txt", "These files live in the iOS app's Documents directory.\nBrowse, edit, download, or delete them from the browser.\n"),
            ("logs/app.log", "[info] app launched\n[info] sandbox server started\n[info] seeded sample files\n"),
        ]
        for (name, body) in files {
            try? body.write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // A large file for Range / suffix-Range testing (~250 KB).
        var big = ""
        big.reserveCapacity(260_000)
        for i in 0..<5000 { big += "line \(i): the quick brown fox jumps over the lazy dog — 0123456789\n" }
        try? big.write(to: docs.appendingPathComponent("data/large.log"), atomically: true, encoding: .utf8)
    }

    // MARK: - Database

    /// Creates a multi-table SQLite DB in Documents. One table (`events`) is intentionally large so
    /// you can see the table list stay instant (row counts fill in lazily via `?counts=true`) and
    /// exercise the virtualized result grid.
    private static func seedDatabase() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = docs.appendingPathComponent("app.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        // DROP first so the schema is always rebuilt fresh — a leftover app.sqlite from an earlier
        // run could otherwise keep an old table shape and make inserts silently fail.
        let schema = """
        PRAGMA journal_mode=WAL;
        DROP TABLE IF EXISTS users; DROP TABLE IF EXISTS products; DROP TABLE IF EXISTS orders;
        DROP TABLE IF EXISTS events; DROP TABLE IF EXISTS audit;
        CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, vip INTEGER);
        CREATE TABLE products(id INTEGER PRIMARY KEY, sku TEXT, title TEXT, price REAL);
        CREATE TABLE orders(id INTEGER PRIMARY KEY, user_id INTEGER, total REAL, status TEXT);
        CREATE TABLE events(id INTEGER PRIMARY KEY, user_id INTEGER, kind TEXT, weight REAL, note TEXT);
        CREATE TABLE audit(id INTEGER PRIMARY KEY, action TEXT);
        INSERT INTO users(name,email,vip) VALUES('Ada Lovelace','ada@example.com',1),('林想','lin@example.com',0),('Bob',NULL,1);
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        bulkInsert(db, "INSERT INTO users(name,email,vip) VALUES(?,?,?)", count: 47) { stmt, i in
            sqlite3_bind_text(stmt, 1, "user_\(i)", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, "u\(i)@example.com", -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(i % 4 == 0 ? 1 : 0))
        }
        bulkInsert(db, "INSERT INTO products(sku,title,price) VALUES(?,?,?)", count: 200) { stmt, i in
            sqlite3_bind_text(stmt, 1, "SKU-\(1000 + i)", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, "Product \(i)", -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Double(i) * 1.99 + 0.5)
        }
        bulkInsert(db, "INSERT INTO orders(user_id,total,status) VALUES(?,?,?)", count: 800) { stmt, i in
            sqlite3_bind_int(stmt, 1, Int32(i % 50))
            sqlite3_bind_double(stmt, 2, Double(i) * 3.25)
            sqlite3_bind_text(stmt, 3, ["paid", "pending", "refunded", "cancelled"][i % 4], -1, SQLITE_TRANSIENT)
        }
        // The big one — ~6000 rows so COUNT(*) is non-trivial and the grid is worth virtualizing.
        bulkInsert(db, "INSERT INTO events(user_id,kind,weight,note) VALUES(?,?,?,?)", count: 6000) { stmt, i in
            sqlite3_bind_int(stmt, 1, Int32(i % 50))
            sqlite3_bind_text(stmt, 2, ["login", "tap", "scroll", "purchase", "error"][i % 5], -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Double(i) * 0.5)
            sqlite3_bind_text(stmt, 4, "event #\(i) — synthetic row for list virtualization", -1, SQLITE_TRANSIENT)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        // `audit` is left empty on purpose, so the table list shows a 0-count table too.
    }

    // MARK: - UserDefaults

    /// Seeds a varied, typed set of UserDefaults so the Defaults panel (and the `defaults_*` MCP
    /// tools) have realistic content to browse and edit — string / bool / int / double / array /
    /// dict / date. Prefixed `demo.` so they're easy to spot among the app's own keys.
    private static func seedDefaults() {
        let d = UserDefaults.standard
        d.set("Ada Lovelace", forKey: "demo.username")
        d.set(true, forKey: "demo.onboarded")
        d.set(false, forKey: "demo.crashReportsOptIn")
        d.set(42, forKey: "demo.launchCount")
        d.set(0.8, forKey: "demo.volume")
        d.set("dark", forKey: "demo.theme")
        d.set(["alpha", "beta", "gamma"], forKey: "demo.featureFlags")
        d.set(["plan": "pro", "seats": 3] as [String: Any], forKey: "demo.profile")
        d.set(Date(), forKey: "demo.lastSync")
        d.set("tok_demo_4f3a9b2c8e", forKey: "demo.apiToken")
    }

    /// Prepares `sql` once and steps it `count` times, calling `bind` to fill the placeholders.
    private static func bulkInsert(_ db: OpaquePointer, _ sql: String, count: Int,
                                   bind: (OpaquePointer?, Int) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for i in 0..<count {
            bind(stmt, i)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    // MARK: - Logs

    private var logTimer: Timer?

    /// Seeds the Logs panel with `count` lines across all levels/sources (a mix of captured `print`
    /// and structured `SandboxServer.log`) and starts a heartbeat so the live stream keeps updating.
    private func seedLogs(_ count: Int) {
        print("[Demo] app launched — console capture is mirroring stdout into the Logs panel")
        emitLogs(count)
        guard logTimer == nil else { return }
        var tick = 0
        logTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            tick += 1
            if tick % 2 == 0 {
                print("[Demo] heartbeat #\(tick) at \(Date())")
            } else {
                self?.server.log("structured heartbeat #\(tick)", level: tick % 5 == 0 ? "error" : "debug", category: "heartbeat")
            }
        }
    }

    /// Emits a burst of varied log lines (for testing the virtualized/streamed Logs panel).
    func emitLogs(_ n: Int) {
        let levels = ["debug", "info", "warn", "error"]
        let cats = ["net", "db", "ui", "auth", "sync", "cache"]
        for i in 0..<n {
            let level = levels[i % levels.count]
            // Mix captured stdout (print) with structured app logs so both sources appear.
            if i % 6 == 0 {
                print("[Demo] stdout log #\(i) — captured from print()/NSLog")
            } else {
                server.log("structured log line #\(i) — \(cats[i % cats.count]) subsystem event with some detail",
                           level: level, category: cats[i % cats.count])
            }
        }
        logCount += n
    }

    // MARK: - Network

    /// Bumped from the Screen panel's remote tap — proves browser → app control end-to-end.
    func bump() {
        tapCount += 1
        server.log("UI button tapped — count=\(tapCount)", level: "info", category: "ui")
    }

    /// Fires `n` varied requests at the app's OWN loopback server so the Network panel fills with
    /// real captured traffic (no internet needed). The mix includes 404s and POSTs carrying a JSON
    /// body, so there's something meaningful to replay via `net_replay_request`.
    func fireLocalBatch(_ n: Int) {
        guard var base = apiBase?.absoluteString else { fireSampleRequest(); return }
        if !base.hasSuffix("/") { base += "/" }
        let token = authToken
        Task { // inherits @MainActor; the awaits suspend without blocking the UI
            for i in 0..<n {
                let (method, path, body) = Self.sampleRequest(i)
                guard let url = URL(string: base + path) else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = method
                if let body {
                    req.httpBody = body
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                _ = try? await URLSession.shared.data(for: req)
                requestCount += 1
                lastRequest = "\(method) \(path)"
            }
        }
    }

    private static func sampleRequest(_ i: Int) -> (method: String, path: String, body: Data?) {
        switch i % 8 {
        case 0: return ("GET", "healthz", nil)
        case 1: return ("GET", "plugins", nil)
        case 2: return ("GET", "fs/roots", nil)
        case 3: return ("GET", "db", nil)
        case 4: return ("GET", "logs?limit=5", nil)
        case 5: return ("GET", "net/requests?limit=5", nil)
        case 6: return ("GET", "does/not/exist?n=\(i)", nil) // a 404 for status variety
        default: return ("POST", "healthz", Data("{\"replayable\":true,\"i\":\(i),\"note\":\"replay me\"}".utf8))
        }
    }

    private var wsTask: URLSessionWebSocketTask?

    /// Opens a WebSocket to a public echo server and keeps receiving, so the WebSocket panel shows
    /// live captured frames (best-effort — needs internet; a failure is captured as a failed conn).
    func openWebSocket() {
        guard let url = URL(string: "wss://ws.postman-echo.com/raw") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        wsTask = task
        task.resume()
        receiveLoop(task)
        sendWebSocket()
    }

    /// Sends a few frames over the open WebSocket (the echo server bounces them back).
    func sendWebSocket() {
        guard let task = wsTask else { return }
        for i in 0..<5 {
            task.send(.string("hello #\(i) from the SandboxServer demo")) { _ in }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard case .success = result else { return } // stop on close/error
            self?.receiveLoop(task)
        }
    }

    /// POSTs a body the demo "encrypts" (XOR) at the app layer, to show the display-only
    /// `networkBodyDecoder` turning it back into readable JSON in the Network panel — while the
    /// bytes on the wire stay ciphertext and `net_replay_request` re-issues them verbatim.
    func fireEncryptedRequest() {
        guard var base = apiBase?.absoluteString else { return }
        if !base.hasSuffix("/") { base += "/" }
        guard let url = URL(string: base + "healthz"),
              let cipher = DemoCrypto.xor(Data(#"{"secret":"hunter2","note":"ciphertext on the wire; decoded only in the console"}"#.utf8))
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = cipher
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("xor", forHTTPHeaderField: "X-Demo-Encrypted")
        if let authToken { req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization") }
        Task {
            _ = try? await URLSession.shared.data(for: req)
            await MainActor.run { self.requestCount += 1; self.lastRequest = "POST healthz (encrypted)" }
        }
    }

    /// Hits a couple of public endpoints too; SandboxURLProtocol captures them automatically.
    /// Best-effort — fine if the simulator has no internet (the local batch covers the panel).
    func fireSampleRequest() {
        let urls = [
            "https://api.github.com/zen",
            "https://httpbin.org/get",
            "https://httpbin.org/status/404",
        ]
        for string in urls {
            guard let url = URL(string: string) else { continue }
            Task {
                _ = try? await URLSession.shared.data(from: url)
                await MainActor.run {
                    self.requestCount += 1
                    self.lastRequest = string
                }
            }
        }
    }
}
