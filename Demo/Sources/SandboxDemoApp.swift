import SwiftUI
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
