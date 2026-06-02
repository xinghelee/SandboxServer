import SwiftUI
import SandboxServerCore
import SandboxServerAPI

@main
struct TasksApp: App {
    @StateObject private var store = TaskStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task { await store.bootstrap() }
        }
    }
}

/// The entire SandboxServer integration. A real app adds roughly this much and nothing else — the
/// rest of the project is just an ordinary to-do app. In DEBUG it boots the embedded server and
/// hands back the console URL; in a Release build it does nothing.
///
/// (This sample links `SandboxServerCore` directly. A production app would depend on the
/// `SandboxServer` facade + `SandboxServerEnabled` trait, so Release links the inert no-op — see
/// the repo README.)
@MainActor
final class DebugConsole: ObservableObject {
    @Published var url: String?
    @Published var status: String = "starting…"

    private let server = SandboxServerCore()

    func start() async {
        #if DEBUG
        // .localNetwork lets another browser / the MCP bridge reach the app over the trusted LAN;
        // captureConsole mirrors print/NSLog into the Logs panel. Auth defaults to .none.
        let config = SandboxConfig(bindingPolicy: .localNetwork, captureConsole: true)
        switch await server.start(config) {
        case .started(let info):
            url = info.consoleURL.absoluteString
            status = "running"
        case .disabled:
            status = "disabled (linked the no-op stub)"
        case .failed(let reason):
            status = "failed: \(reason)"
        }
        #else
        status = "off (Release build)"
        #endif
    }

    /// App-side logging that lands in the console's **Logs** panel (structured) and the device
    /// console (`print`). A no-op-safe call even before/without a running server.
    func log(_ message: String, level: String = "info", category: String = "tasks") {
        server.log(message, level: level, category: category)
        print("[Tasks] \(message)")
    }
}
