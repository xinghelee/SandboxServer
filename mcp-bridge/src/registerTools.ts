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
import { DeviceApiError, TransportError } from "./deviceClient.js";
import { log } from "./log.js";

type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string };

type CallResult = {
  content: ContentBlock[];
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
const optNum = z.number().optional();

/** Substitute {placeholders} in a path suffix from args, consuming used keys. */
export function fillPath(suffix: string, args: Record<string, unknown>, consumed: Set<string>): string {
  return suffix.replace(/\{(\w+)\}/g, (_m, key: string) => {
    consumed.add(key);
    const v = args[key];
    if (v === undefined || v === null) {
      throw new Error(`Missing path parameter "${key}" for ${suffix}`);
    }
    return encodeURIComponent(String(v));
  });
}

export function pickQuery(args: Record<string, unknown>, keys: string[]): Record<string, string | number | boolean> {
  const q: Record<string, string | number | boolean> = {};
  for (const k of keys) {
    const v = args[k];
    if (v !== undefined && v !== null && v !== "") q[k] = v as string | number | boolean;
  }
  return q;
}

/**
 * Build the JSON body for POST /net/requests/{id}/replay from tool args.
 * - `method` and `url` replace the original request line when provided.
 * - `headers` (object) pass straight through — the device MERGES them onto the captured request's
 *   original (unredacted) headers, so only the headers you want to change need to be sent and the
 *   original auth is preserved unless you override that key.
 * - `body` is taken as a UTF-8 string and base64-encoded here (the device decodes base64).
 * Omitted fields fall back to the original captured request on the device. An empty result ({})
 * therefore re-issues the request faithfully.
 */
export function buildReplayBody(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (typeof args.method === "string" && args.method.trim() !== "") {
    out.method = args.method.trim().toUpperCase();
  }
  if (typeof args.url === "string" && args.url.trim() !== "") {
    out.url = args.url.trim();
  }
  if (args.headers && typeof args.headers === "object" && !Array.isArray(args.headers)) {
    out.headers = args.headers;
  }
  if (typeof args.body === "string") {
    out.body = Buffer.from(args.body, "utf8").toString("base64");
  }
  return out;
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
    shape: {
      id: str.describe("request id to replay"),
      method: optStr.describe("replacement HTTP method; omit to keep the captured method"),
      url: optStr.describe("replacement URL; omit to keep the captured URL"),
      headers: z
        .record(z.string(), z.string())
        .optional()
        .describe("header overrides MERGED onto the original request (only changed keys needed; original auth is kept unless you override it)"),
      body: optStr.describe("replacement request body as UTF-8 text; omit to resend the original body unchanged"),
    },
    invoke: (device, _d, args) =>
      device.post(`/net/requests/${encodeURIComponent(String(args.id))}/replay`, buildReplayBody(args)),
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
    // The device route (POST /db/{dbId}/query) accepts EITHER a read-only `sql`
    // SELECT or a `table` to browse, paginated with `limit` + `cursor`. (It does
    // not bind `?` params, so we don't forward any.)
    shape: {
      dbId: str,
      sql: optStr.describe("read-only SELECT to run; omit to browse a table instead"),
      table: optStr.describe("browse this table instead of running SQL"),
      limit: optInt.describe("max rows to return (default 100, max 1000)"),
      cursor: optStr.describe("pagination cursor from a previous page's nextCursor"),
    },
    invoke: (device, _d, args) => {
      if (!args.sql && !args.table) {
        throw new Error("db_query requires either 'sql' (a read-only SELECT) or 'table' (to browse).");
      }
      return device.post(
        `/db/${encodeURIComponent(String(args.dbId))}/query`,
        pickQuery(args, ["sql", "table", "limit", "cursor"]),
      );
    },
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

  // ---- screen (mirror + control) -----------------------------------------
  ui_info: {
    shape: {},
    invoke: (device) => device.get("/screen"),
  },
  ui_screenshot: {
    shape: {
      maxWidth: optInt.describe("downscale the longest edge to this many points"),
      quality: optNum.describe("JPEG quality 0.1–1.0"),
    },
    invoke: (device, _d, args) => device.get("/screen/snapshot", pickQuery(args, ["maxWidth", "quality"])),
  },
  ui_tap: {
    shape: { x: z.number().describe("window point x"), y: z.number().describe("window point y") },
    invoke: (device, _d, args) => device.post("/screen/tap", { x: args.x, y: args.y }),
  },
  ui_swipe: {
    shape: {
      from: z.object({ x: z.number(), y: z.number() }).describe("start window point"),
      to: z.object({ x: z.number(), y: z.number() }).describe("end window point"),
      duration: optNum.describe("seconds (default 0.3)"),
    },
    invoke: (device, _d, args) =>
      device.post("/screen/swipe", { from: args.from, to: args.to, duration: args.duration ?? 0.3 }),
  },
  ui_type: {
    shape: { text: str.describe("text to insert into the focused field"), clear: z.boolean().optional() },
    invoke: (device, _d, args) => device.post("/screen/text", { text: args.text, clear: args.clear ?? false }),
  },
  ui_paste: {
    shape: { text: str.describe("text to set on the pasteboard and paste") },
    invoke: (device, _d, args) => device.post("/screen/paste", { text: args.text }),
  },

  // ---- app bundle / IPA payload inspector --------------------------------
  bundle_summary: {
    shape: {},
    invoke: (device) => device.get("/bundle"),
  },
  bundle_macho: {
    shape: {},
    invoke: (device) => device.get("/bundle/macho"),
  },
  bundle_security: {
    shape: {},
    invoke: (device) => device.get("/bundle/security"),
  },
  bundle_provisioning: {
    shape: {},
    invoke: (device) => device.get("/bundle/provisioning"),
  },
  bundle_privacy: {
    shape: {},
    invoke: (device) => device.get("/bundle/privacy"),
  },
  bundle_decode_plist: {
    shape: { path: str.describe("absolute path to a .plist/.strings file inside an allowed root") },
    invoke: (device, _d, args) => device.get("/bundle/plist", pickQuery(args, ["path"])),
  },

  // ---- view hierarchy -----------------------------------------------------
  ui_hierarchy: {
    shape: {
      maxDepth: optInt.describe("max tree depth to walk"),
      maxNodes: optInt.describe("cap on total nodes returned"),
    },
    invoke: (device, _d, args) => device.get("/hierarchy", pickQuery(args, ["maxDepth", "maxNodes"])),
  },
  // ---- perf ---------------------------------------------------------------
  perf_snapshot: {
    shape: {},
    invoke: (device) => device.get("/perf"),
  },

  // ---- UserDefaults inspector/editor -------------------------------------
  defaults_list: {
    shape: {
      scope: optStr.describe("app (default; the app's own persisted keys) or all (full resolved dictionary)"),
      suite: optStr.describe("App Group / custom UserDefaults suite name"),
      prefix: optStr.describe("only keys starting with this prefix"),
    },
    invoke: (device, _d, args) => device.get("/defaults", pickQuery(args, ["scope", "suite", "prefix"])),
  },
  defaults_get: {
    shape: { key: str, suite: optStr.describe("App Group / custom suite name") },
    invoke: (device, _d, args) => device.get("/defaults/value", pickQuery(args, ["key", "suite"])),
  },
  defaults_set: {
    shape: {
      key: str,
      value: z.unknown().describe("JSON value to store (string/number/bool/array/object); null removes the key"),
      type: optStr.describe("coerce a string value: int | double | bool | string"),
      suite: optStr.describe("App Group / custom suite name"),
    },
    invoke: (device, _d, args) =>
      device.put("/defaults/value", { key: args.key, value: args.value ?? null, type: args.type, suite: args.suite }),
  },
  defaults_delete: {
    shape: { key: str, suite: optStr.describe("App Group / custom suite name") },
    invoke: (device, _d, args) => device.del("/defaults/value", pickQuery(args, ["key", "suite"])),
  },
  defaults_reset: {
    shape: { suite: optStr.describe("App Group / custom suite name; omit to reset the app's own domain") },
    invoke: (device, _d, args) => device.post("/defaults/reset", { suite: args.suite }),
  },

  // ---- device / runtime info ---------------------------------------------
  device_info: {
    shape: {},
    invoke: (device) => device.get("/device"),
  },

  // ---- deep links / URL schemes ------------------------------------------
  deeplink_list_schemes: {
    shape: {},
    invoke: (device) => device.get("/deeplink"),
  },
  deeplink_open: {
    shape: { url: str.describe("URL to open: a custom scheme (myapp://path) or universal/https link") },
    invoke: (device, _d, args) => device.post("/deeplink/open", { url: args.url }),
  },

  // ---- notifications ------------------------------------------------------
  notify_settings: {
    shape: {},
    invoke: (device) => device.get("/notify"),
  },
  notify_request_auth: {
    shape: {
      alert: z.boolean().optional().describe("request alert authorization (default true)"),
      sound: z.boolean().optional().describe("request sound authorization (default true)"),
      badge: z.boolean().optional().describe("request badge authorization (default true)"),
    },
    invoke: (device, _d, args) =>
      device.post("/notify/auth", { alert: args.alert ?? true, sound: args.sound ?? true, badge: args.badge ?? true }),
  },
  notify_send_local: {
    shape: {
      title: optStr,
      subtitle: optStr,
      body: optStr,
      badge: optInt.describe("app icon badge number"),
      sound: z.boolean().optional().describe("play the default sound (default true)"),
      delay: optNum.describe("seconds before firing (0 = immediate)"),
      identifier: optStr.describe("request id; omit to auto-generate"),
      userInfo: z.record(z.string(), z.unknown()).optional().describe("custom payload merged into the notification"),
    },
    invoke: (device, _d, args) =>
      device.post("/notify/local", {
        title: args.title,
        subtitle: args.subtitle,
        body: args.body,
        badge: args.badge,
        sound: args.sound,
        delay: args.delay,
        identifier: args.identifier,
        userInfo: args.userInfo,
      }),
  },
  notify_list_pending: {
    shape: {},
    invoke: (device) => device.get("/notify/pending"),
  },
  notify_list_delivered: {
    shape: {},
    invoke: (device) => device.get("/notify/delivered"),
  },
  notify_simulate_remote: {
    shape: {
      payload: z
        .record(z.string(), z.unknown())
        .describe("aps-style push payload, e.g. { aps: { alert: 'hi', badge: 1 }, customKey: '…' }"),
    },
    invoke: (device, _d, args) => device.post("/notify/remote", { payload: args.payload }),
  },
  notify_clear: {
    shape: { scope: optStr.describe("pending | delivered | all (default all)") },
    invoke: (device, _d, args) => device.del("/notify", pickQuery(args, ["scope"])),
  },
};

/**
 * Fallback binding for tools reported by the manifest that we have no static
 * shape for. We forward generically using the descriptor's backing method +
 * path suffix, substituting {placeholders} from args and sending the rest as
 * query (GET/DELETE) or JSON body (POST/PUT).
 *
 * `backingPathSuffix` is relative to the plugin's mount point (e.g. "roots",
 * "{dbId}/query"), so we prefix the plugin id — otherwise an unbound tool like
 * `fs_roots` would resolve to /roots instead of /fs/roots and 404 on the device.
 */
function fallbackBinding(pluginId: string): ToolBinding {
  return {
    // Permissive: accept any string params; the device validates.
    shape: { args: z.record(z.string(), z.unknown()).optional().describe("raw parameters forwarded to the device") },
    invoke: (device, descriptor, raw) => {
      const args = (raw.args as Record<string, unknown> | undefined) ?? raw;
      const consumed = new Set<string>();
      const path = `${pluginId}/${fillPath(descriptor.backingPathSuffix, args, consumed)}`;
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

/** Render a tool result. A `{ jpegBase64 }` payload (ui_screenshot) becomes an MCP image block. */
function resultContent(data: unknown): CallResult {
  if (data && typeof data === "object" && typeof (data as { jpegBase64?: unknown }).jpegBase64 === "string") {
    const d = data as { jpegBase64: string; width?: number; height?: number };
    return {
      content: [
        { type: "image", data: d.jpegBase64, mimeType: "image/jpeg" },
        { type: "text", text: `device screen ${d.width ?? "?"}×${d.height ?? "?"} pt` },
      ],
    };
  }
  return {
    content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    structuredContent: toStructured(data),
  };
}

// ---------------------------------------------------------------------------
// Failure classification — tell the consumer WHICH kind of failure occurred so
// it can choose fix-args vs treat-as-device-error vs wait/wake-the-device.
// ---------------------------------------------------------------------------

export type ErrorKind = "input" | "device" | "unreachable";

interface Classified {
  kind: ErrorKind;
  code?: string;
  status?: number;
  /** TransportError sub-reason, carried for hint precision only (not the public kind). */
  reason?: string;
  message: string;
}

/**
 * Map any thrown value to a stable failure kind via a pure instanceof ladder
 * (no message sniffing). Order is load-bearing: DeviceApiError is only thrown
 * when the device answered non-2xx; TransportError only at the fetch reject
 * site; everything else is a pre-call/programmer error the model can fix.
 */
export function classifyError(err: unknown): Classified {
  if (err instanceof DeviceApiError) {
    return { kind: "device", code: err.code, status: err.status, message: err.message };
  }
  if (err instanceof TransportError) {
    return { kind: "unreachable", code: err.code ?? err.reason, reason: err.reason, message: err.message };
  }
  return { kind: "input", message: err instanceof Error ? err.message : String(err) };
}

/** One imperative remediation sentence. Advisory prose; the machine signal is `kind` (+ status/code). */
export function hintFor(c: Classified): string {
  if (c.kind === "device") {
    switch (c.status) {
      case 401:
        return "Auth token rejected. Set SANDBOX_TOKEN to a fresh token (re-open the console URL or restart the device server to mint one), then retry.";
      case 403:
        return "Forbidden: the path escaped its allowed root, or this is a read-only/blocked operation (e.g. DB exec, fs traversal). Don't retry as-is — pick a different path/operation.";
      case 404:
        return "Not found: that id/path/table/dbId doesn't exist on the device. List first (net_list_requests, db_list_tables, fs_list_dir), then retry with a real id.";
      case 400:
        return "The device rejected the arguments. Fix the parameter values per the message, then retry.";
      case 501:
        return "Not implemented in this SDK version — the route is wired but not live. Skip it; don't retry.";
      default:
        if (c.status !== undefined && c.status >= 500) {
          return `Device internal error (HTTP ${c.status}). Retry once; if it persists, inspect logs_tail.`;
        }
        return `Device returned HTTP ${c.status ?? "?"}${c.code ? ` (${c.code})` : ""}.`;
    }
  }
  if (c.kind === "unreachable") {
    switch (c.reason) {
      case "timeout":
        return "No response within the timeout. The device may be backgrounded/asleep — foreground the app (or raise SANDBOX_TIMEOUT_MS), then retry.";
      case "connect_refused":
        return "Connection refused — nothing is listening. The host app's server isn't started (it must call start() in a DEBUG build); confirm host/port, then retry.";
      case "dns":
        return "Host could not be resolved. Re-discover the device (mDNS) or fix the host/IP, then retry.";
      case "reset":
        return "Connection reset mid-flight. Retry.";
      case "host_unreachable":
        return "Network unreachable — check the device is on the same Wi-Fi/LAN, then retry.";
      case "aborted":
        return "The request was cancelled by the caller. Re-issue only if still needed.";
      default:
        return "Could not reach the device (connection failed). Confirm it's awake and reachable, then retry.";
    }
  }
  return "Fix the tool arguments and call again — the request never left the bridge.";
}

/** Shared failure formatter used by every tool callback (machine-readable + human-readable). */
export function errorResult(err: unknown, tool: string): CallResult {
  const c = classifyError(err);
  const hint = hintFor(c);
  const error: Record<string, unknown> = { kind: c.kind, message: c.message, hint, tool };
  if (c.code !== undefined) error.code = c.code;
  if (c.status !== undefined) error.status = c.status;
  const head = `Error [${c.kind}${c.status !== undefined ? " " + c.status : ""}${c.code ? "/" + c.code : ""}]`;
  return {
    isError: true,
    content: [{ type: "text", text: `${head}: ${c.message}\n${hint}` }],
    structuredContent: { error },
  };
}

export function buildCallback(device: DeviceClient, descriptor: McpToolDescriptor, binding: ToolBinding) {
  return async (args: Record<string, unknown>): Promise<CallResult> => {
    try {
      const data = await binding.invoke(device, descriptor, args ?? {});
      return resultContent(data);
    } catch (err) {
      log.warn(
        `tool ${descriptor.name} failed [${classifyError(err).kind}]: ${err instanceof Error ? err.message : String(err)}`,
      );
      return errorResult(err, descriptor.name);
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
        return errorResult(err, "sandbox_status");
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
      const binding = BINDINGS[descriptor.name] ?? fallbackBinding(plugin.id);
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
