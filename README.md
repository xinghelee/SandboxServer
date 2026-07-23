# SandboxServer

**English** · [简体中文](README.zh-CN.md)

A **DEBUG-only iOS SDK** that turns any app into a browsable debug target. Integrate it, call
`start()`, and from a browser on the same network you get:

- 🗂 **Sandbox file browser** — list / preview / edit / download / delete, Range streaming, root-confined (**live**)
- 🌐 **Live network capture** — every `URLSession` request, inspectable in real time (**live**)
- 🗄 **Database viewer** — discover SQLite DBs, browse tables/schema, run read-only SQL (**live**; Core Data/Realm + writes later)
- 📜 **Live logs** — stream the app's console output (`SandboxServer.log`, plus `print`/`NSLog` when console capture is on) to the browser, level-filtered (**live**)
- 📱 **Screen mirror + control** — watch the app's UI live in the browser and drive it: tap (UIControls / SwiftUI buttons), **swipe/scroll & drag** (real synthesized touch), type, and paste (**live, iOS**)
- 🌳 **View hierarchy** — inspect the live view tree (frames, classes, labels, thumbnails) as a list or a **3D layer explorer** in the browser (**live, iOS**)
- 🔌 **WebSocket capture** — every `URLSessionWebSocketTask` connection and its sent/received frames, streamed live (**live**)
- 📈 **Performance HUD** — live FPS / CPU / memory footprint / thermal state, streamed and charted (**live**)
- 📦 **App bundle inspector** — Info.plist, Mach-O architectures + hardening, provisioning, privacy, plist decode (**live**)
- ⚙️ **UserDefaults editor** — browse, edit, delete & reset the app's persisted defaults and App Group suites (**live**)
- 📲 **Device info** — model / OS / locale / screen + safe-area / battery / memory / free disk at a glance (**live**)
- ⛓️ **Deep-link trigger** — list the app's URL schemes and open any scheme / universal link in the app (**live, iOS**)
- 🔔 **Notification tester** — inspect/request authorization, fire local notifications, simulate a remote push payload (**live, iOS**)
- 🖥 **A web console** served by the SDK itself — no app to install, just open a URL
- 🤖 **MCP tools** — the same on-device API re-exposed to AI clients (Claude Code / Desktop)

It runs an embedded HTTP + WebSocket server **inside the host process** on Apple's
Network.framework, with **zero third-party runtime dependencies**.

> ⚠️ This SDK exposes full read/write access to the host app's sandbox. It is **off by default**,
> requires an explicit `start()`, binds loopback by default, and is **physically absent from
> Release/App Store builds**. Token auth is opt-in; if you bind to `.localNetwork` without enabling
> it, every device on the trusted LAN can reach the console. Use non-production accounts on a
> trusted network.

---

## Architecture

```
┌─ host iOS app (DEBUG) ──────────────────────────────┐
│  SandboxServer.shared.start()                        │
│     │                                                │
│     ▼                                                │
│  SandboxServerCore                                   │
│   ├ NetworkFrameworkTransport  (NWListener/NWConn)   │
│   ├ HTTP/1.1 + RFC 6455 WebSocket  (hand-rolled)     │
│   ├ AuthGate + DNS-rebinding guard  (middleware)     │
│   ├ Router → PluginRegistry → WSHub                  │
│   └ Plugins:  net·fs·db·logs·screen·hierarchy·ws·    │
│              perf·bundle·defaults·device·deeplink·    │
│              notify                                   │
│  serves:                                             │
│   • web console  (/, /assets/*)                      │
│   • REST + WS API (/__sandbox/api/v1, /__sandbox/ws) │
└──────────────────────────────────────────────────────┘
        ▲ LAN / localhost                ▲ LAN / localhost
        │                                │
   browser (Preact console)        sandbox-mcp (stdio) ──► Claude Code / Desktop
```

The core is tiny and feature-agnostic — **everything is a `SandboxPlugin`**. A plugin's
self-described capabilities (`GET /__sandbox/api/v1/plugins`) drive *both* which console panels
render *and* which MCP tools the bridge registers.

| Module | Role |
| --- | --- |
| `SandboxServerAPI` | Dependency-free public contract (`SandboxPlugin`, request/response, config). |
| `SandboxServer` | Always-linked facade. Forwards to Core (DEBUG + trait) or the no-op stub. |
| `SandboxServerNoOp` | Inert mirror linked in Release / disabled builds. |
| `SandboxServerCore` | The real server: transport, router, hub, registry, built-in plugins, web assets. |
| `web-src/` | The Preact + TypeScript console (Vite). Build output is committed under `Sources/SandboxServerCore/Resources/web/`. |
| `mcp-bridge/` | Standalone `sandbox-mcp` npm package (separate from the Swift SDK). |

---

## Install

### Swift Package Manager (recommended)

```swift
dependencies: [
    // Enable the SandboxServerEnabled trait when adding the dependency:
    .package(url: "https://github.com/xinghelee/SandboxServer.git", from: "0.1.0",
             traits: ["SandboxServerEnabled"]),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SandboxServer", package: "SandboxServer"),
    ]),
]
```

In an Xcode app project, add the package via **Package Dependencies** and tick the
`SandboxServerEnabled` trait there instead (requires Xcode 16.3+ / Swift 6.1 traits support).

Even with the trait on, Release builds still link the inert no-op — the facade is gated on
`#if DEBUG && SandboxServerEnabled`. Without the trait, the real server is physically absent
from every build.

### CocoaPods

```ruby
pod 'SandboxServer', :configurations => ['Debug']
```

`:configurations => ['Debug']` keeps the binary **and the web assets** out of Release builds.
(CocoaPods support is preliminary — validate with `pod lib lint` before publishing.)

---

## Use

```swift
import SandboxServer

#if DEBUG
Task {
    // Built-in plugins (network/files/db) are auto-registered from the config.
    let result = await SandboxServer.shared.start()        // .loopback, all built-ins, by default
    if case .started(let info) = result {
        print("Open \(info.consoleURL)")                   // add auth: .token if you want ?token=
    }
}

// Opt into a subset, or add your own plugin (conform to the public `SandboxPlugin`):
// SandboxServer.shared.register(MyCustomPlugin())
// await SandboxServer.shared.start(SandboxConfig(builtInPlugins: [.network]))
#endif
```

The console URL is printed to the Xcode console. On the **Simulator** open it directly
(`http://127.0.0.1:<port>/`). On a **device**, start with `.localNetwork` and open the printed LAN
URL from a browser on the same Wi-Fi:

```swift
await SandboxServer.shared.start(SandboxConfig(bindingPolicy: .localNetwork))
```

`.localNetwork` requires `NSLocalNetworkUsageDescription` (and `NSBonjourServices` listing
`_sandboxserver._tcp`) in your **debug** Info.plist.

### SwiftUI lifecycle

`start()` is `async` and `App.init()` is not, so kick it off from a `Task` in the initializer (a
root-view `.task {}` works too). The call site compiles unchanged in Release — the facade is a
no-op there — but wrapping it in `#if DEBUG` keeps the intent explicit:

```swift
import SwiftUI
import SandboxServer            // import this one product; the public types come along

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Task {
            let result = await SandboxServer.shared.start()        // .loopback, all built-ins
            if case .started(let info) = result {
                print("🧰 Sandbox console → \(info.consoleURL)")
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

On a **device**, pass `SandboxConfig(bindingPolicy: .localNetwork, auth: .token)` and add the
Info.plist keys above; the printed URL then carries `?token=…` for the browser to bootstrap from.

### Reading encrypted / encoded request bodies

HTTPS is **already plaintext here** — capture is in-process, above TLS, so you never install a
proxy CA. `gzip`/`zlib` bodies are auto-inflated. For bodies your app encrypts/encodes at the
**application layer**, plug in a display-only decoder — it runs in-process (keys never leave the
app or reach the console/MCP), only feeds the body *preview*, and never alters the bytes your app
actually sends/receives or what `replay` re-issues:

```swift
var config = SandboxConfig(bindingPolicy: .localNetwork)
config.networkBodyDecoder = { body in            // body: NetworkBody (direction/url/headers/contentType/raw bytes)
    guard body.url.contains("api.myapp.com") else { return nil }   // nil → fall back to the default preview
    guard let clear = MyCrypto.decrypt(body.body) else { return "⚠️ decrypt failed (\(body.body.count)B)" }
    return String(data: clear, encoding: .utf8)                    // shown in the console/MCP only
}
await SandboxServer.shared.start(config)
```

---

## MCP (AI tools)

The `mcp-bridge/` package is a standalone MCP server that proxies the device API. Point your AI
client at it:

```json
{
  "mcpServers": {
    "sandbox": {
      "command": "npx",
      "args": ["-y", "sandbox-mcp"],
      "env": { "SANDBOX_HOST": "127.0.0.1", "SANDBOX_PORT": "8080" }
    }
  }
}
```

It discovers the device (env/flags → single Bonjour match), then registers one MCP tool per
plugin-declared capability (`net_list_requests`, `fs_read_file`, `db_query`, …). See
`mcp-bridge/README.md`.

---

## Develop

```bash
# Swift package (the SDK)
swift build --traits SandboxServerEnabled          # build the real core
swift test  --traits SandboxServerEnabled          # unit + end-to-end tests
swift build                                        # build the Release-safe no-op path

# Web console (Preact)
cd web-src && npm install && npm run build          # output → Sources/SandboxServerCore/Resources/web
VITE_API_BASE=http://<device-ip>:<port> npm run dev # HMR against a running device

# MCP bridge
cd mcp-bridge && npm install && npm run build
```

### Local dev host (browser, no device)

`SandboxServerDevHost` boots the real core on macOS so you can open the console in a browser
without an iOS app — handy when working on `web-src/` or the REST/WS API:

```bash
swift run --traits SandboxServerEnabled SandboxServerDevHost   # then open the printed http://127.0.0.1:8080/ URL
```

Env knobs (each is "set = on"); `Ctrl-C` to stop:

| Var | Effect | Default |
| --- | --- | --- |
| `PORT` | Listen port | `8080` |
| `TOKEN` | Require a session token (URL becomes `…/?token=…`) | off (`auth: .none`) |
| `CAPTURE` | Redirect `print` / `NSLog` into the logs panel (`captureConsole`) | off |
| `LOGSEED` | Emit sample log lines + a 2 s heartbeat so the logs panel has data | off |
| `SEED` | Fire a few sample requests so the network panel has data | off |

```bash
PORT=8092 LOGSEED=1 SEED=1 swift run --traits SandboxServerEnabled SandboxServerDevHost
```

It binds loopback and registers the temp dir as an extra browsable/writable root. Being a macOS
host it has no UIKit, so the **screen mirror** and **view hierarchy** panels report unsupported —
use `Examples/Showcase/run.sh` (iOS Simulator) for those. There are no fallback ports, so if `PORT` is busy it
fails fast — pick a free one.

See `CLAUDE.md` for the full architecture notes and open questions.
