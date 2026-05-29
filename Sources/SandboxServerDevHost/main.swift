// A tiny macOS host that boots the real server so you can open the console in a browser
// during development:
//
//   swift run --traits SandboxServerEnabled SandboxServerDevHost
//   # then open the http://127.0.0.1:8080/?token=… URL it prints
//
// Env: PORT (default 8080), TOKEN=1 to require a session token (off by default, matching the SDK).
#if SandboxServerEnabled
import Foundation
import SandboxServerCore
import SandboxServerAPI

let core = SandboxServerCore()
// Expose the temp dir as an extra browsable/writable root for local fs testing.
core.addRoot(URL(fileURLWithPath: NSTemporaryDirectory()))
let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
let useToken = ProcessInfo.processInfo.environment["TOKEN"] != nil

Task {
    let result = await core.start(SandboxConfig(
        bindingPolicy: .loopback,
        auth: useToken ? .token : .none,
        builtInPlugins: .all,
        preferredPort: port,
        fallbackPorts: [],
        captureConsole: ProcessInfo.processInfo.environment["CAPTURE"] != nil
    ))
    if case .failed(let reason) = result {
        FileHandle.standardError.write(Data("start failed: \(reason)\n".utf8))
        exit(1)
    }

    // Optional: emit log lines so the Logs panel streams live (LOGSEED=1).
    if ProcessInfo.processInfo.environment["LOGSEED"] != nil {
        core.log("devhost started — structured app log", level: "info", category: "devhost")
        core.log("warning sample so you can see level colors", level: "warn", category: "devhost")
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            tick += 1
            if tick % 2 == 0 { print("[DevHost] heartbeat #\(tick)") }
            else { core.log("structured heartbeat #\(tick)", level: tick % 5 == 0 ? "error" : "debug", category: "beat") }
        }
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
