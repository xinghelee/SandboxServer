import SwiftUI
import SQLite3
import SandboxServerCore
import SandboxServerAPI

// SQLite wants this for TEXT binds that it should copy (the Swift String is transient).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@main
struct SandboxDemoApp: App {
    @StateObject private var model = ServerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.start() }
        }
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
        // A token is required whenever the server is exposed beyond this device.
        // captureConsole mirrors print/NSLog into the Logs panel; SandboxServer.log adds structured lines.
        let result = await server.start(SandboxConfig(bindingPolicy: .localNetwork, auth: .token, captureConsole: true))
        switch result {
        case .started(let info):
            consoleURL = info.consoleURL.absoluteString
            token = info.token ?? "(none)"
            apiBase = info.apiBaseURL
            authToken = info.token
            state = .running
            Self.seedSandbox()   // files of varied sizes (incl. a large one for Range testing)
            Self.seedDatabase()  // a multi-table DB with one big table (cheap-counts + grid virtualization)
            seedLogs(250)        // a few hundred log lines + a live heartbeat
            fireLocalBatch(150)  // a few hundred captured requests (net virtualization + replay)
            fireSampleRequest()  // a few real external requests too, best-effort
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
