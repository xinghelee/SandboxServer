# sandbox-mcp

An [MCP](https://modelcontextprotocol.io) bridge for **SandboxServer**, an iOS
debug SDK. It connects to a running device, reads the device's live plugin
manifest, and exposes the network / files / database plugins as MCP tools and
resources over **stdio** — so Claude Code, Claude Desktop, or any MCP client can
inspect captured network traffic, the app sandbox file system, and embedded
databases.

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
npx -y sandbox-mcp doctor --host 127.0.0.1 --port 8765 --token <TOKEN>
```

## Endpoint resolution

The endpoint is resolved with this precedence:

1. **Explicit config** — `SANDBOX_HOST` / `SANDBOX_PORT` / `SANDBOX_TOKEN`
   (env), or `--host` / `--port` / `--token` (flags).
2. **Single Bonjour match** — browses `_sandboxserver._tcp`; if exactly one
   device resolves, it auto-connects using its host:port + TXT record.
3. **Multiple devices** — the bridge lists the peers and asks you to pin one
   explicitly (set `SANDBOX_HOST`/`SANDBOX_PORT`).

A bearer token is required whenever the device reports `requiresAuth`.

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
        "SANDBOX_PORT": "8765",
        "SANDBOX_TOKEN": "your-device-token"
      }
    }
  }
}
```

Omit the `env` block to rely on Bonjour auto-discovery (works when exactly one
device is on the network).

## Tools

`sandbox_status` is always registered. The rest are driven by the device
manifest; the documented initial set is:

| Plugin | Tools |
| --- | --- |
| net | `net_list_requests`, `net_get_request`, `net_replay_request`, `net_clear` |
| fs  | `fs_list_dir`, `fs_read_file`, `fs_stat`, `fs_write_file`, `fs_delete`, `fs_move` |
| db  | `db_list_databases`, `db_list_tables`, `db_get_schema`, `db_query`, `db_exec` |

> In SandboxServer v1 the **net** plugin is live; most **fs**/**db** endpoints
> return `501 not_implemented`. The tools still register (driven by the
> manifest) and forward calls, surfacing the `not_implemented` error.

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
