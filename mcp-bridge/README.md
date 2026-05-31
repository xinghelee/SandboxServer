# sandbox-mcp

An [MCP](https://modelcontextprotocol.io) bridge for **SandboxServer**, an iOS
debug SDK. It connects to a running device, reads the device's live plugin
manifest, and exposes every plugin — network, files, databases, logs, on-screen
mirror/control, the view hierarchy, and captured WebSocket traffic — as MCP tools
and resources over **stdio**, so Claude Code, Claude Desktop, or any MCP client can
inspect captured network + WebSocket traffic, the app sandbox file system, embedded
databases and logs, and even screenshot and drive the running UI.

Tools are registered **dynamically from the live `/plugins` manifest**: as the
device reports new plugins, new tools appear automatically. The static
`sandbox_status` tool is always present.

## Requirements

- Node.js 18+ (uses the global `fetch`)
- A SandboxServer-enabled **debug** build of your app, running and reachable on
  the network (or on `localhost` when the device binds loopback).

## Install / run

The server is designed to be launched on demand by your MCP client via `npx`.
No global install needed.

```bash
# discover devices on the LAN
npx -y sandbox-mcp discover

# health check (warns if buildConfig != debug)
npx -y sandbox-mcp doctor --host 127.0.0.1 --port 8765
```

## Endpoint resolution

The endpoint is resolved with this precedence:

1. **Explicit config** — `SANDBOX_HOST` / `SANDBOX_PORT` (env), with optional
   `SANDBOX_TOKEN`, or `--host` / `--port` / `--token` (flags).
2. **Single Bonjour match** — browses `_sandboxserver._tcp`; if exactly one
   device resolves, it auto-connects using its host:port + TXT record.
3. **Multiple devices** — the bridge lists the peers and asks you to pin one
   explicitly (set `SANDBOX_HOST`/`SANDBOX_PORT`).

A bearer token is only required when the device reports `requiresAuth`.

## Claude Code / Claude Desktop config

Add to your MCP client config (e.g. `claude_desktop_config.json`, or
`.mcp.json` for Claude Code):

```json
{
  "mcpServers": {
    "sandbox": {
      "command": "npx",
      "args": ["-y", "sandbox-mcp"],
      "env": {
        "SANDBOX_HOST": "127.0.0.1",
        "SANDBOX_PORT": "8765"
      }
    }
  }
}
```

Omit the `env` block to rely on Bonjour auto-discovery (works when exactly one
device is on the network).

## Tools

`sandbox_status` is always registered (device reachability + identity). Every
other tool is driven by the live `/plugins` manifest — as the device reports
plugins, their tools appear automatically. The full v1 tool set:

| Plugin | Tools | Status |
| --- | --- | --- |
| **net** | `net_list_requests`, `net_get_request`, `net_replay_request`, `net_clear`† | Live. Captures `URLSession` traffic into a ring buffer; `net_replay_request` re-issues a captured request (optionally with header/body overrides). |
| **fs** | `fs_roots`, `fs_list_dir`, `fs_stat`, `fs_read_file`, `fs_write_file`†, `fs_move`, `fs_delete`† | Live. Confined to the app container + host-registered roots (traversal → 403). Reads support HTTP Range. |
| **db** | `db_list_databases`, `db_list_tables`, `db_get_schema`, `db_query`, `db_exec`† | Read-only. SQLite over a `SQLITE_OPEN_READONLY` connection; `db_query` runs a `SELECT`. `db_exec` (mutations) returns **403** in v1. |
| **logs** | `logs_tail`, `logs_search`, `logs_clear`† | Live. Tails the SDK logger, host `SandboxServer.log`, and (opt-in) redirected `stdout`/`stderr`. |
| **screen** | `ui_info`, `ui_screenshot`, `ui_tap`, `ui_swipe`, `ui_type`, `ui_paste` | Live on iOS (UIKit). `ui_screenshot` returns an **image content block**. Non-UIKit hosts report `supported:false` and 503 the capture/control routes. |
| **hierarchy** | `ui_hierarchy` | Live on iOS (UIKit). Snapshots the live view tree (frames, classes, labels, optional thumbnails). |
| **ws** | `ws_list_connections`, `ws_get_connection`, `ws_list_messages`, `ws_clear`† | Live. Captures `URLSessionWebSocketTask` connections + sent/received frames. Not captured: raw-socket WS libraries or ping/pong/close control frames. |
| **perf** | `perf_snapshot` | Live. One-shot FPS / CPU % / memory footprint / frame hitch / thermal state. FPS/hitch need UIKit (null otherwise). |
| **bundle** | `bundle_summary`, `bundle_macho`, `bundle_security`, `bundle_provisioning`, `bundle_privacy`, `bundle_decode_plist` | Live. App bundle / IPA payload inspector: Info.plist, Mach-O archs + hardening score, provisioning, privacy, plist→JSON. |
| **defaults** | `defaults_list`, `defaults_get`, `defaults_set`, `defaults_delete`†, `defaults_reset`† | Live (read/write). Browse/edit `UserDefaults`; `scope=app\|all`, optional `suite`. Values are JSON; a `null` value removes a key. |
| **device** | `device_info` | Live. One-shot device + runtime snapshot: model, OS, locale, screen + safe-area, battery, memory, free disk, thermal. |
| **deeplink** | `deeplink_list_schemes`, `deeplink_open` | Live on iOS. Lists declared `CFBundleURLTypes`; `deeplink_open` opens a scheme / universal link via `UIApplication.open`. 503 on a non-UIKit host. |

`†` = **destructive** (`destructiveHint:true` — mutates or discards data). The
`ui_*` tap/swipe/type/paste tools drive the UI but are not flagged destructive.
Every tool carries the `readOnly`/`destructive` hints straight from the device
manifest, so MCP clients can gate them.

## Resources

- `sandbox://fs/{path}` — a file's contents from the app sandbox
- `sandbox://net/{id}/{part}` — a captured request part
  (`reqHeaders|reqBody|respHeaders|respBody|full`)
- `sandbox://db/{dbId}/{table}` — a table's schema

Bodies larger than ~256 KB are not inlined; the bridge returns a note pointing
back to the resource instead.

## Development

```bash
npm install
npm run build      # tsc -> dist/
npm run dev        # tsx watch src/index.ts
npm run discover   # tsx src/index.ts discover
npm run doctor     # tsx src/index.ts doctor
```

Set `SANDBOX_MCP_LOG=debug` for verbose stderr logging. **All** logging goes to
stderr — stdout is reserved for the JSON-RPC stream.
