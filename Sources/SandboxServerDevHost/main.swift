// A tiny macOS host that boots the real server so you can open the console in a browser
// during development:
//
//   swift run --traits SandboxServerEnabled SandboxServerDevHost
//   # then open the http://127.0.0.1:8080/?token=… URL it prints
//
// Env: PORT (default 8080), NO_TOKEN=1 to disable the session token (loopback dev only).
#if SandboxServerEnabled
import Foundation
import SandboxServerCore
import SandboxServerAPI

let core = SandboxServerCore()
let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
let useToken = ProcessInfo.processInfo.environment["NO_TOKEN"] == nil

Task {
    let result = await core.start(SandboxConfig(
        bindingPolicy: .loopback,
        auth: useToken ? .token : .none,
        builtInPlugins: .all,
        preferredPort: port,
        fallbackPorts: []
    ))
    if case .failed(let reason) = result {
        FileHandle.standardError.write(Data("start failed: \(reason)\n".utf8))
        exit(1)
    }

    // Optional: fire a few in-process requests so the Network panel has live data to show.
    if ProcessInfo.processInfo.environment["SEED"] != nil {
        let urls = [
            "https://api.github.com/zen",
            "https://httpbin.org/get",
            "https://httpbin.org/status/404",
            "https://httpbin.org/json",
            "https://httpbin.org/status/500",
        ]
        for s in urls {
            if let u = URL(string: s) { Task { _ = try? await URLSession.shared.data(from: u) } }
        }
    }
}

RunLoop.main.run()
#else
import Foundation
FileHandle.standardError.write(Data("SandboxServerDevHost requires --traits SandboxServerEnabled\n".utf8))
#endif
