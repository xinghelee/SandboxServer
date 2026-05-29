import SwiftUI
import SQLite3
import SandboxServerCore
import SandboxServerAPI

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

/// Boots the embedded debug server and drives some sample traffic so the Network panel has
/// something live to show.
@MainActor
final class ServerModel: ObservableObject {
    enum State { case starting, running, disabled, failed(String) }

    @Published var state: State = .starting
    @Published var consoleURL: String = ""
    @Published var token: String = ""
    @Published var requestCount: Int = 0
    @Published var lastRequest: String = "—"

    private let server = SandboxServerCore()

    func start() async {
        #if DEBUG
        // Loopback is reachable from the Mac's browser because the Simulator shares localhost.
        let result = await server.start(SandboxConfig(bindingPolicy: .loopback))
        switch result {
        case .started(let info):
            consoleURL = info.consoleURL.absoluteString
            token = info.token ?? "(none)"
            state = .running
            Self.seedSandbox()  // create a few files so the Files panel has content to browse
            Self.seedDatabase() // create a SQLite db so the Databases panel has content
            fireSampleRequest() // seed the network capture
        case .disabled:
            state = .disabled
        case .failed(let reason):
            state = .failed(reason)
        }
        #else
        state = .disabled
        #endif
    }

    /// Writes a few sample files into the app's Documents so the Files panel has content.
    private static func seedSandbox() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? fm.createDirectory(at: docs.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("welcome.json", "{\n  \"app\": \"SandboxServer Demo\",\n  \"sandbox\": true,\n  \"editable\": true\n}\n"),
            ("notes.txt", "These files live in the iOS app's Documents directory.\nBrowse, edit, download, or delete them from the browser.\n"),
            ("logs/app.log", "[info] app launched\n[info] sandbox server started\n[info] seeded sample files\n"),
        ]
        for (name, body) in files {
            try? body.write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Creates a small SQLite database in Documents so the Databases panel has real content.
    private static func seedDatabase() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = docs.appendingPathComponent("app.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, vip INTEGER);
        DELETE FROM users;
        INSERT INTO users(name,email,vip) VALUES('Ada Lovelace','ada@example.com',1),('林想','lin@example.com',0),('Bob',NULL,1);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), kind TEXT, weight REAL);
        DELETE FROM events;
        INSERT INTO events(user_id,kind,weight) VALUES(1,'login',1.0),(1,'tap',2.5),(2,'login',3.25);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Hits a couple of public endpoints; SandboxURLProtocol captures them automatically.
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
