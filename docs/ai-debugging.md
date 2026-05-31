# Driving SandboxServer from an AI client (MCP)

The `sandbox-mcp` bridge re-exposes a running device's on-device API to any MCP client
(Claude Code / Desktop). One stdio session lets the model **observe and drive a live app**:
inspect captured network/logs, query the sandbox DB, read/write files & UserDefaults, take a
screenshot, walk the view hierarchy, tap/type, and fire notifications — all on a real build a
tester is holding, no rebuild or test target required.

> Validated end-to-end against the iOS-simulator demo on 2026-05-31: bridge auto-connected,
> **13 plugins / 53 tools** registered, and a full debugging session ran (see the recipe below).

## Connect

The bridge resolves a device three ways (first match wins):

1. **Explicit** — `SANDBOX_HOST` / `SANDBOX_PORT` (+ `SANDBOX_TOKEN` if the device uses `auth: .token`),
   or `--host/--port/--token`.
2. **Bonjour** — if exactly one `_sandboxserver._tcp` peer is on the LAN, it auto-connects.
3. Multiple peers → it lists them and asks you to pin one.

Verify connectivity first:

```bash
SANDBOX_HOST=127.0.0.1 SANDBOX_PORT=8080 npx -y sandbox-mcp doctor   # probes /healthz, checks debug build
npx -y sandbox-mcp discover                                          # list LAN devices
```

MCP client config (`.mcp.json` / desktop client) — the in-app **MCP** console panel prints this
filled in with the live host/port/token:

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

Tools are generated from the live plugin manifest (`GET /__sandbox/api/v1/plugins`), so the catalog
changes automatically as plugins are enabled/disabled — that manifest is the source of truth.
`sandbox_status` is always present (reachability + app identity).

## A typical debugging session

```
1. orient   device_info            → model / OS / locale / screen+safe-area / disk / memory
            bundle_summary         → app id, version, bundle path
2. observe  net_list_requests      → recent captured HTTP (filter by host/status/since)
            net_get_request {id}   → full headers + bodies for one
            logs_tail / logs_search→ console + structured logs
3. inspect  ui_screenshot          → JPEG image block of the current screen
            ui_hierarchy           → view tree (frames, classes, a11y labels)
4. state    db_list_databases → db_query {dbId, table|sql}   → read app data
            fs_list_dir {path} / fs_read_file {path}
            defaults_list / defaults_get
5. drive    defaults_set / fs_write_file        → change state
            ui_tap / ui_type / ui_swipe          → operate the UI
            net_replay_request {id, overrides}   → re-issue a request, tweaked
            notify_send_local / notify_simulate_remote
6. repeat — screenshot again to confirm the effect
```

## Path & id conventions

- **`fs_*` paths** may be **absolute** (within a root reported by `fs_roots`) **or relative to the
  app container** — e.g. `fs_list_dir {path:"Documents"}` or `fs_stat {path:"Documents/app.sqlite"}`.
  An empty/`"/"` path lists the container root. `..` traversal out of a root is rejected (403).
- **`db_*` `dbId`** is the database's absolute file path, exactly as returned by `db_list_databases`.
  Pass it back verbatim to `db_list_tables` / `db_query`.
- **`defaults` suites** — omit `suite` for the app's own defaults; pass an App Group / custom suite
  name to target it. `scope=app` (default) lists the app's own keys, `scope=all` the full dictionary.

## Known limitations / gaps

- **`ui_tap` is coordinate-based.** Tapping blind can hit a non-actionable view. The robust flow is
  `ui_hierarchy` → locate an actionable element → tap its frame center. (Label-based tapping —
  `ui_tap("Login")` — is a planned improvement that would remove the guesswork.)
- **Simulator quirks** — battery reports `level:-1 / unknown`; some signals differ from a device.
- **iOS-only tools** — `ui_*`, `ui_hierarchy`, `notify_*`, `deeplink_*` report `supported:false` /
  503 on a non-UIKit host (e.g. the macOS dev host). `device_info` / `net` / `fs` / `db` / `logs` /
  `bundle` / `defaults` work everywhere.
- **`notify_simulate_remote`** invokes the app delegate's `didReceiveRemoteNotification` in-process —
  it does **not** go through APNs and returns `delivered:false` if the app has no such handler.
- **Network capture blind spots** — background sessions, `WKWebView`, raw sockets, non-HTTP schemes
  (surfaced in the `net` plugin's `limitations`).
