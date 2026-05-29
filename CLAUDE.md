# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SandboxServer is a **DEBUG-only iOS SDK** that embeds an HTTP + WebSocket server inside a host
app. It serves a browser web console and a token-authenticated REST/WS API for browsing the
sandbox file system, databases, and live network traffic. The same on-device API is consumed by a
standalone MCP bridge so AI clients can drive it. **Zero third-party runtime dependencies** — the
transport is hand-rolled on Apple's Network.framework.

Three codebases live here:
- **Swift SDK** (`Package.swift`, `Sources/`) — the embedded server. The primary, validated artifact.
- **`web-src/`** — the Preact + TypeScript console (Vite). Build output is committed into
  `Sources/SandboxServerCore/Resources/web/` and served by the SDK. **Edit `web-src/`, never the
  committed `Resources/web/` output directly.**
- **`mcp-bridge/`** — the standalone `sandbox-mcp` npm package (its own module graph; not part of SPM).

## Commands

```bash
# Swift SDK — the real server is gated behind the SandboxServerEnabled trait:
swift build --traits SandboxServerEnabled                 # build the real core
swift test  --traits SandboxServerEnabled                 # run all tests (unit + end-to-end)
swift build                                               # build the Release-safe NO-OP path (no trait)

# Single test:
swift test --traits SandboxServerEnabled \
  --filter SandboxServerCoreTests.WebSocketCodecTests/testAcceptKeyMatchesRFCExample

# Web console:
cd web-src && npm install && npm run build                # → Sources/SandboxServerCore/Resources/web
VITE_API_BASE=http://<device-ip>:<port> npm run dev       # HMR proxied to a running device

# MCP bridge:
cd mcp-bridge && npm install && npm run build             # tsc → dist/

# iOS demo (xcodegen + simulator) — proves the SDK on a real iOS app end-to-end:
cd Demo && ./run.sh                                        # build → install → launch → open console URL
# manual: xcodegen generate; xcodebuild -project Demo/SandboxServerDemo.xcodeproj \
#   -scheme SandboxServerDemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build

# Run the server on macOS for quick browser testing:
swift run --traits SandboxServerEnabled SandboxServerDevHost
```

> Running `swift build`/`swift test` **without** `--traits SandboxServerEnabled` exercises the
> no-op path: `SandboxServerCore` is not in the dependency graph and all tests compile to empty
> (each test file is wrapped in `#if SandboxServerEnabled`). Both paths must stay green.

The package declares `.macOS(.v11)` in addition to `.iOS(.v14)` **solely so the package builds and
tests on a Mac host** (the end-to-end test boots a real server on loopback). iOS is the product
target; UIKit-only code is behind `#if canImport(UIKit)`.

## The one abstraction that matters: `SandboxPlugin`

The core (`SandboxServerCore`) knows nothing about files, databases, or networking. Every feature
is a `SandboxPlugin` (defined in `Sources/SandboxServerAPI/SandboxPlugin.swift`) mounted under
`/__sandbox/api/v1/<id>/`. A plugin's `capabilities` (`PluginCapabilities`) are aggregated into the
manifest at `GET /__sandbox/api/v1/plugins`, and **that single manifest drives both** which web
console panel renders (`panelKey`) **and** which MCP tools the bridge registers (`mcpTools`). To add
a feature, conform to `SandboxPlugin` and `register()` it — touch nothing in the transport/router.

Request/response flow: `NetworkFrameworkTransport` accepts a connection → `HTTPConnectionReader`
parses the request → `MiddlewareChain` (auth + DNS-rebinding host check) runs **before any plugin**
→ `Router.match` resolves the plugin route → the plugin handler returns an `SBResponse`. WebSocket
upgrades (`/__sandbox/ws`) are handed to the `WSHub` actor, which fans events to subscribers over a
single multiplexed connection (`{channel, type, seq, payload}`, `seq` monotonic per channel).

`PluginContext` is the only handle a plugin gets to the running server: `publish` (WS events),
`extraRoots`, `hostValue`, `config`, `log`. It deliberately does not expose the transport or hub.

## Wire contract (frozen — web console + MCP both depend on it)

- REST under `/__sandbox/api/v1`; success `{ "data": …, "meta": { apiVersion, ts } }`,
  error `{ "error": { code, message, details } }`, lists `{ data: { items, nextCursor } }`.
- `GET /healthz`, `GET /plugins` (manifest), then per-plugin routes under `/<id>/`.
- Network plugin is **live** (`/net/requests`, `/net/requests/{id}`, `DELETE /net/requests`,
  `net` WS channel). File plugin is **live** (`/fs/roots`, `/fs/list`, `/fs/stat`, `/fs/file`
  GET/PUT with Range, `/fs/move`, `DELETE /fs/file`) — every path is confined to an allowed root
  (app container + host-registered extra roots; traversal → 403). DB plugin is **live** (read-only):
  `GET /db` scans for SQLite files; `/db/{dbId}/tables`, `/db/{dbId}/tables/{table}/schema`, and
  `POST /db/{dbId}/query` (browse a table or run a SELECT) read via a `SQLITE_OPEN_READONLY`
  connection (`SQLiteReader`), so writes fail; `dbId` is the file path, confined via `FilePlugin.resolve`.
  `POST /db/{dbId}/exec` (mutations) → 403 in this version.

## DEBUG-only gating — four independent layers (do not weaken)

1. **Compile-time:** SPM trait `SandboxServerEnabled` gates `SandboxServerCore` as a *conditional
   dependency* of the facade; the facade switches on `#if DEBUG && SandboxServerEnabled` between
   the real core and `SandboxServerNoOp`. CocoaPods uses `:configurations => ['Debug']` +
   `-D SandboxServerEnabled`. The default (no trait) links the inert no-op product.
2. **Runtime opt-in:** the server never autostarts; the host must call `start()`.
3. **`ReleaseGuard`:** refuses to start in an App Store / TestFlight environment, independent of
   `#if DEBUG` (allows Simulator + macOS for dev).
4. **Per-session token:** a fresh 128-bit token minted each `start()`, enforced in the middleware
   before any plugin, constant-time compared. Static console assets are served *without* the token
   so the browser can bootstrap from `?token=`; everything under `/__sandbox/api` and `/__sandbox/ws`
   requires it.

`SandboxServerNoOp` must stay a source/binary-compatible mirror of the public API — both it and the
real core conform to `SandboxServerEngine`, and `PublicAPICompatTests` enforces this by compiling
the facade against both. If you add a public method to one engine, add it to the other.

**Products & the trait-tooling gap.** The package exposes four library products: `SandboxServer`
(the recommended, Release-safe facade), `SandboxServerNoOp`, `SandboxServerAPI` (depend on this to
author custom plugins), and `SandboxServerCore` (the real server, **ungated**). The Core product
exists because Xcode 26 / xcodegen 2.42 cannot yet enable an SPM trait from a generated `.xcodeproj`,
so the `Demo/` app and `SandboxServerDevHost` link `SandboxServerCore` directly. Do **not** ship the
Core product in a Release app — production integration is the facade + trait (enabled via Xcode's
Package Dependencies pane). The built-in plugins are `internal`; the host opts in via
`SandboxConfig.builtInPlugins` (auto-registered in `start()`), never by naming the plugin types.

## Gotchas

- **Network capture** (`SandboxURLProtocol`) uses the Wormholy technique: `URLProtocol.registerClass`
  (covers `URLSession.shared`) **plus** swizzling `URLSessionConfiguration.protocolClasses` (covers
  sessions from `.default`/`.ephemeral`). Recursion is prevented by a `handled` property marker on the
  replayed request, **not** by excluding the protocol — the internal replay session uses the default
  (swizzled) config and relies on the marker. Blind spots: background sessions, `WKWebView`, raw sockets.
- The `web-src` build output is committed; a source/artifact drift check belongs in CI
  (`vite build` then diff `Sources/SandboxServerCore/Resources/web`).
- Inter-module `import` statements (`SandboxServerAPI`/`Core`/`NoOp`) are wrapped in `#if SWIFT_PACKAGE`
  so the same sources compile as one CocoaPods module. Keep that guard when adding cross-module imports.

## Open questions (carried from the architecture design; resolve before the relevant work)

- **Token on loopback/Simulator:** currently uniform (always required). Revisit only if dev friction
  warrants a Simulator-only waiver — apply identically to console + MCP if changed.
- **CocoaPods** support is preliminary; validate with `pod lib lint` (single-module fold) before publishing.
- **DB write/Core Data editing:** v1 is discovery + read-only by design; structured Core Data edits
  need a host-provided `NSManagedObjectContext` (the only corruption-safe path) — a v2 product call.
- **`SandboxServerAPI` as a public third-party SPI:** kept internal for v1; freeze at 1.0.0 only after
  all three built-in plugins have dogfooded it.
- **Console panels** are a single monolithic bundle keyed off the manifest in v1; dynamic per-plugin
  panel loading was deferred (would reintroduce a CSP/trust surface).
