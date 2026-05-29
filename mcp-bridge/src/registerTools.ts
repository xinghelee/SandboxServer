/**
 * registerTools — wire the live device manifest into MCP tools + resources.
 *
 * Flow:
 *   1. Register the static `sandbox_status` tool (GET /healthz + GET /plugins).
 *   2. Fetch /plugins and DYNAMICALLY register one tool per mcpTools[]
 *      descriptor across every plugin. Registration is driven by the live
 *      manifest, so tools auto-appear/disappear as the device reports plugins.
 *   3. Register ResourceTemplates for fs / net / db.
 *
 * Each dynamic tool maps the descriptor's backingMethod + backingPathSuffix to
 * a DeviceClient call. Inputs are validated with a zod raw shape chosen per the
 * known initial tool set; unknown tools fall back to a permissive shape so the
 * bridge still forwards them.
 */

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z, type ZodRawShape } from "zod";
import type { DeviceClient, McpToolDescriptor, PluginDescriptor } from "./deviceClient.js";
import { log } from "./log.js";

type CallResult = {
  content: { type: "text"; text: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

// ---------------------------------------------------------------------------
// Per-tool input shapes (zod raw shapes) + arg -> request mapping.
// ---------------------------------------------------------------------------

interface ToolBinding {
  shape: ZodRawShape;
  /** Build the actual device call from validated args + the descriptor. */
  invoke: (
    device: DeviceClient,
    descriptor: McpToolDescriptor,
    args: Record<string, unknown>,
  ) => Promise<unknown>;
}

const str = z.string();
const optStr = z.string().optional();
const optInt = z.number().int().optional();

/** Substitute {placeholders} in a path suffix from args, consuming used keys. */
function fillPath(suffix: string, args: Record<string, unknown>, consumed: Set<string>): string {
  return suffix.replace(/\{(\w+)\}/g, (_m, key: string) => {
    consumed.add(key);
    const v = args[key];
    if (v === undefined || v === null) {
      throw new Error(`Missing path parameter "${key}" for ${suffix}`);
    }
    return encodeURIComponent(String(v));
  });
}

function pickQuery(args: Record<string, unknown>, keys: string[]): Record<string, string | number | boolean> {
  const q: Record<string, string | number | boolean> = {};
  for (const k of keys) {
    const v = args[k];
    if (v !== undefined && v !== null && v !== "") q[k] = v as string | number | boolean;
  }
  return q;
}

const BINDINGS: Record<string, ToolBinding> = {
  // ---- network -----------------------------------------------------------
  net_list_requests: {
    shape: {
      cursor: optStr,
      limit: optInt,
      method: optStr,
      host: optStr,
      statusClass: optStr.describe("e.g. 2xx, 4xx, 5xx"),
      since: optStr.describe("unix seconds or ISO timestamp lower bound"),
    },
    invoke: (device, _d, args) =>
      device.get("/net/requests", pickQuery(args, ["cursor", "limit", "method", "host", "statusClass", "since"])),
  },
  net_get_request: {
    shape: {
      id: str.describe("request id"),
      include: optStr.describe("comma list: reqHeaders,reqBody,respHeaders,respBody"),
    },
    invoke: (device, _d, args) =>
      device.get(`/net/requests/${encodeURIComponent(String(args.id))}`, pickQuery(args, ["include"])),
  },
  net_replay_request: {
    shape: { id: str.describe("request id to replay") },
    invoke: (device, _d, args) => device.post(`/net/requests/${encodeURIComponent(String(args.id))}/replay`),
  },
  net_clear: {
    shape: {},
    invoke: (device) => device.del("/net/requests"),
  },

  // ---- files (v1: mostly 501, shapes still wired) ------------------------
  fs_list_dir: {
    shape: { path: str, cursor: optStr, limit: optInt },
    invoke: (device, _d, args) => device.get("/fs/list", pickQuery(args, ["path", "cursor", "limit"])),
  },
  fs_stat: {
    shape: { path: str },
    invoke: (device, _d, args) => device.get("/fs/stat", pickQuery(args, ["path"])),
  },
  fs_read_file: {
    shape: { path: str },
    invoke: async (device, _d, args) => {
      const body = await device.fetchBody("/fs/file", pickQuery(args, ["path"]));
      return body;
    },
  },
  fs_write_file: {
    shape: { path: str, content: str.describe("file content to write (utf8)") },
    invoke: (device, _d, args) =>
      device.put("/fs/file", { content: args.content }, { query: pickQuery(args, ["path"]) }),
  },
  fs_delete: {
    shape: { path: str, recursive: z.boolean().optional() },
    invoke: (device, _d, args) => device.del("/fs/file", pickQuery(args, ["path", "recursive"])),
  },
  fs_move: {
    shape: { from: str, to: str },
    invoke: (device, _d, args) => device.post("/fs/move", { from: args.from, to: args.to }),
  },

  // ---- database (v1: only db_list_databases is real) ---------------------
  db_list_databases: {
    shape: {},
    invoke: (device) => device.get("/db"),
  },
  db_list_tables: {
    shape: { dbId: str },
    invoke: (device, _d, args) => device.get(`/db/${encodeURIComponent(String(args.dbId))}/tables`),
  },
  db_get_schema: {
    shape: { dbId: str, table: str },
    invoke: (device, _d, args) =>
      device.get(`/db/${encodeURIComponent(String(args.dbId))}/tables/${encodeURIComponent(String(args.table))}/schema`),
  },
  db_query: {
    shape: { dbId: str, sql: str.describe("read-only SQL query"), params: z.array(z.unknown()).optional() },
    invoke: (device, _d, args) =>
      device.post(`/db/${encodeURIComponent(String(args.dbId))}/query`, { sql: args.sql, params: args.params ?? [] }),
  },
  db_exec: {
    shape: { dbId: str, sql: str.describe("mutating SQL statement"), params: z.array(z.unknown()).optional() },
    invoke: (device, _d, args) =>
      device.post(`/db/${encodeURIComponent(String(args.dbId))}/exec`, { sql: args.sql, params: args.params ?? [] }),
  },

  // ---- logs ---------------------------------------------------------------
  logs_tail: {
    shape: {
      limit: optInt.describe("max lines (newest first)"),
      sinceSeq: optInt.describe("only lines with seq greater than this"),
    },
    invoke: (device, _d, args) => device.get("/logs", pickQuery(args, ["limit", "sinceSeq"])),
  },
  logs_search: {
    shape: {
      q: optStr.describe("substring to match in the message"),
      level: optStr.describe("debug | info | warn | error"),
      limit: optInt,
    },
    invoke: (device, _d, args) => device.get("/logs", pickQuery(args, ["q", "level", "limit"])),
  },
  logs_clear: {
    shape: {},
    invoke: (device) => device.del("/logs"),
  },
};

/**
 * Fallback binding for tools reported by the manifest that we have no static
 * shape for. We forward generically using the descriptor's backing method +
 * path suffix, substituting {placeholders} from args and sending the rest as
 * query (GET/DELETE) or JSON body (POST/PUT).
 */
function fallbackBinding(): ToolBinding {
  return {
    // Permissive: accept any string params; the device validates.
    shape: { args: z.record(z.string(), z.unknown()).optional().describe("raw parameters forwarded to the device") },
    invoke: (device, descriptor, raw) => {
      const args = (raw.args as Record<string, unknown> | undefined) ?? raw;
      const consumed = new Set<string>();
      const path = fillPath(descriptor.backingPathSuffix, args, consumed);
      const method = descriptor.backingMethod.toUpperCase();
      const rest: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(args)) if (!consumed.has(k)) rest[k] = v;
      if (method === "GET") return device.get(path, rest as Record<string, string | number | boolean>);
      if (method === "DELETE") return device.del(path, rest as Record<string, string | number | boolean>);
      if (method === "PUT") return device.put(path, rest);
      return device.post(path, rest);
    },
  };
}

function toStructured(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return { result: value };
}

function buildCallback(device: DeviceClient, descriptor: McpToolDescriptor, binding: ToolBinding) {
  return async (args: Record<string, unknown>): Promise<CallResult> => {
    try {
      const data = await binding.invoke(device, descriptor, args ?? {});
      const structured = toStructured(data);
      return {
        content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
        structuredContent: structured,
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      log.warn(`tool ${descriptor.name} failed: ${message}`);
      return {
        content: [{ type: "text", text: `Error: ${message}` }],
        isError: true,
      };
    }
  };
}

// ---------------------------------------------------------------------------
// Static status tool
// ---------------------------------------------------------------------------

function registerStatusTool(server: McpServer, device: DeviceClient): void {
  server.registerTool(
    "sandbox_status",
    {
      title: "Sandbox status",
      description:
        "Report the connected SandboxServer device: health (apiVersion, buildConfig, deviceName, " +
        "appBundleId, bindingPolicy) plus the live plugin manifest and the MCP tools each plugin exposes.",
      inputSchema: {},
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async (): Promise<CallResult> => {
      try {
        const [health, plugins] = await Promise.all([device.healthz(), device.plugins()]);
        const data = { health, plugins: plugins.items };
        return {
          content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
          structuredContent: data as unknown as Record<string, unknown>,
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return { content: [{ type: "text", text: `Error: ${message}` }], isError: true };
      }
    },
  );
  log.debug("registered tool sandbox_status");
}

// ---------------------------------------------------------------------------
// Dynamic tools from the manifest
// ---------------------------------------------------------------------------

function registerPluginTools(server: McpServer, device: DeviceClient, plugins: PluginDescriptor[]): number {
  let count = 0;
  for (const plugin of plugins) {
    for (const descriptor of plugin.mcpTools ?? []) {
      const binding = BINDINGS[descriptor.name] ?? fallbackBinding();
      try {
        server.registerTool(
          descriptor.name,
          {
            title: descriptor.title,
            description: descriptor.description,
            inputSchema: binding.shape,
            annotations: {
              readOnlyHint: descriptor.readOnlyHint,
              destructiveHint: descriptor.destructiveHint,
              openWorldHint: false,
            },
          },
          buildCallback(device, descriptor, binding),
        );
        count++;
        log.debug(`registered tool ${descriptor.name} (plugin ${plugin.id})`);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        log.warn(`could not register tool ${descriptor.name}: ${message}`);
      }
    }
  }
  return count;
}

// ---------------------------------------------------------------------------
// Resource templates
// ---------------------------------------------------------------------------

function registerResources(server: McpServer, device: DeviceClient): void {
  // sandbox://fs/{path} -> a file's contents
  server.registerResource(
    "sandbox-fs",
    new ResourceTemplate("sandbox://fs/{+path}", { list: undefined }),
    {
      title: "Sandbox file",
      description: "Read a file from the device sandbox by path (sandbox://fs/<path>).",
    },
    async (uri, variables) => {
      const path = decodeURIComponent(String(variables.path ?? ""));
      const body = await device.fetchBody("/fs/file", { path });
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: body.contentType ?? "text/plain",
            text: body.text ?? body.note ?? "(empty)",
          },
        ],
      };
    },
  );

  // sandbox://net/{id}/{part} -> a captured request's part
  server.registerResource(
    "sandbox-net",
    new ResourceTemplate("sandbox://net/{id}/{part}", { list: undefined }),
    {
      title: "Sandbox network request part",
      description:
        "Read part of a captured network request: part = reqHeaders|reqBody|respHeaders|respBody|full.",
    },
    async (uri, variables) => {
      const id = String(variables.id ?? "");
      const part = String(variables.part ?? "full");
      const include = part === "full" ? "reqHeaders,reqBody,respHeaders,respBody" : part;
      const record = await device.get(`/net/requests/${encodeURIComponent(id)}`, { include });
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: "application/json",
            text: JSON.stringify(record, null, 2),
          },
        ],
      };
    },
  );

  // sandbox://db/{dbId}/{table} -> a table's schema
  server.registerResource(
    "sandbox-db",
    new ResourceTemplate("sandbox://db/{dbId}/{table}", { list: undefined }),
    {
      title: "Sandbox database table schema",
      description: "Read a table's schema from a device database (sandbox://db/<dbId>/<table>).",
    },
    async (uri, variables) => {
      const dbId = String(variables.dbId ?? "");
      const table = String(variables.table ?? "");
      const schema = await device.get(
        `/db/${encodeURIComponent(dbId)}/tables/${encodeURIComponent(table)}/schema`,
      );
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: "application/json",
            text: JSON.stringify(schema, null, 2),
          },
        ],
      };
    },
  );

  log.debug("registered resource templates: fs, net, db");
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

export interface RegisterResult {
  toolCount: number;
  pluginCount: number;
}

/** Register status tool, dynamic plugin tools, and resource templates. */
export async function registerAll(server: McpServer, device: DeviceClient): Promise<RegisterResult> {
  registerStatusTool(server, device);

  const plugins = await device.plugins();
  const dynamic = registerPluginTools(server, device, plugins.items);
  registerResources(server, device);

  return {
    // +1 for sandbox_status
    toolCount: dynamic + 1,
    pluginCount: plugins.items.length,
  };
}
