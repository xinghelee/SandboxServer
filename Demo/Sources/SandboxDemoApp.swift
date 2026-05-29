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
            fireSampleRequest() // seed the capture
        case .disabled:
            state = .disabled
        case .failed(let reason):
            state = .failed(reason)
        }
        #else
        state = .disabled
        #endif
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
