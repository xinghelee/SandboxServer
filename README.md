# SandboxServer

**English** · [简体中文](README.zh-CN.md)

A **DEBUG-only iOS SDK** that turns any app into a browsable debug target. Integrate it, call
`start()`, and from a browser on the same network you get:

- 🗂 **Sandbox file browser** — list / preview / edit / download / delete, Range streaming, root-confined (**live**)
- 🌐 **Live network capture** — every `URLSession` request, inspectable in real time (**live**)
- 🗄 **Database viewer** — discover SQLite DBs, browse tables/schema, run read-only SQL (**live**; Core Data/Realm + writes later)
- 🖥 **A web console** served by the SDK itself — no app to install, just open a URL
- 🤖 **MCP tools** — the same on-device API re-exposed to AI clients (Claude Code / Desktop)

It runs an embedded HTTP + WebSocket server **inside the host process** on Apple's
Network.framework, with **zero third-party runtime dependencies**.

> ⚠️ This SDK exposes full read/write access to the host app's sandbox over the local network to
> anyone holding the session token. It is **off by default**, requires an explicit `start()` and a
> per-session token, binds loopback by default, and is **physically absent from Release/App Store
> builds**. Use non-production accounts on a trusted network.

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
│   └ Plugins:  net (live) · fs (stub) · db (stub)     │
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
    .package(url: "https://github.com/your-org/SandboxServer.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        // Enable the real server ONLY in your debug build configuration:
        .product(name: "SandboxServer", package: "SandboxServer",
                 condition: .when(traits: ["SandboxServerEnabled"])),
    ]),
]
```

Enable the `SandboxServerEnabled` trait for your debug builds. Without it (Release), the package
links the inert no-op product and the server is physically absent.

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
        print("Open \(info.consoleURL)")                   // includes the bootstrap ?token=
    }
}

// Opt into a subset, or add your own plugin (conform to the public `SandboxPlugin`):
// SandboxServer.shared.register(MyCustomPlugin())
// await SandboxServer.shared.start(SandboxConfig(builtInPlugins: [.network]))
#endif
```

The console URL is printed to the Xcode console with the session token baked in. On the
**Simulator** open it directly (`http://127.0.0.1:<port>/?token=…`). On a **device**, start with
`.localNetwork` and open the printed LAN URL from a browser on the same Wi-Fi:

```swift
await SandboxServer.shared.start(SandboxConfig(bindingPolicy: .localNetwork))
```

`.localNetwork` requires `NSLocalNetworkUsageDescription` (and `NSBonjourServices` listing
`_sandboxserver._tcp`) in your **debug** Info.plist.

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
      "env": { "SANDBOX_HOST": "127.0.0.1", "SANDBOX_PORT": "8080", "SANDBOX_TOKEN": "<token>" }
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

See `CLAUDE.md` for the full architecture notes and open questions.
