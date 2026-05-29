/**
 * deviceClient — thin fetch wrapper around the SandboxServer REST API.
 *
 * - Prefixes every path with /__sandbox/api/v1
 * - Adds `Authorization: Bearer <token>`
 * - Unwraps the frozen REST envelope: success -> `data`, error -> throws
 * - Caps inline text bodies at ~256KB; larger payloads are surfaced as a
 *   note/resource reference rather than inlined into a tool result.
 */

import { log } from "./log.js";

export const API_PREFIX = "/__sandbox/api/v1";

/** Max bytes we are willing to inline as text in a tool/resource result. */
export const MAX_INLINE_BYTES = 256 * 1024;

export interface Endpoint {
  host: string;
  port: number;
  token: string;
  /** "http" — SandboxServer binds loopback/local network over plain HTTP. */
  scheme?: "http" | "https";
}

export interface DeviceError {
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

/** Thrown when the server returns an `{ error: {...} }` envelope. */
export class DeviceApiError extends Error {
  readonly code: string;
  readonly status: number;
  readonly details: Record<string, unknown>;
  constructor(status: number, err: DeviceError) {
    super(err.message || err.code || `HTTP ${status}`);
    this.name = "DeviceApiError";
    this.code = err.code ?? "unknown";
    this.status = status;
    this.details = err.details ?? {};
  }
}

export interface HealthzData {
  apiVersion: string;
  buildConfig: string;
  deviceName: string;
  appBundleId: string;
  bindingPolicy: "loopback" | "localNetwork";
  requiresAuth: boolean;
}

export interface McpToolDescriptor {
  name: string;
  title: string;
  description: string;
  readOnlyHint: boolean;
  destructiveHint: boolean;
  backingMethod: string;
  backingPathSuffix: string;
}

export interface PluginDescriptor {
  id: "fs" | "db" | "net" | string;
  version: string;
  title: string;
  panelKey: string;
  routes: string[];
  channels: string[];
  mcpTools: McpToolDescriptor[];
}

export interface PluginsData {
  items: PluginDescriptor[];
}

/** Result of a raw text/binary fetch where we may have skipped inlining. */
export interface BodyResult {
  /** Decoded text body, present only when within the inline cap. */
  text?: string;
  /** Total byte length reported by the response. */
  byteLength: number;
  /** Content-Type as reported by the server, if any. */
  contentType: string | null;
  /** True when the body exceeded MAX_INLINE_BYTES and was NOT inlined. */
  truncated: boolean;
  /** Human-readable note when truncated, suitable for surfacing to the model. */
  note?: string;
}

type Query = Record<string, string | number | boolean | undefined | null>;

export interface RequestOptions {
  query?: Query;
  body?: unknown;
  /** Override Accept header / signal etc. */
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

export class DeviceClient {
  readonly endpoint: Endpoint;
  private readonly base: string;

  constructor(endpoint: Endpoint) {
    this.endpoint = endpoint;
    const scheme = endpoint.scheme ?? "http";
    this.base = `${scheme}://${endpoint.host}:${endpoint.port}`;
  }

  /** Build a fully-qualified URL for a path suffix relative to the API prefix. */
  buildUrl(pathSuffix: string, query?: Query): string {
    const suffix = pathSuffix.startsWith("/") ? pathSuffix : `/${pathSuffix}`;
    const url = new URL(API_PREFIX + suffix, this.base);
    if (query) {
      for (const [k, v] of Object.entries(query)) {
        if (v === undefined || v === null || v === "") continue;
        url.searchParams.set(k, String(v));
      }
    }
    return url.toString();
  }

  private authHeaders(extra?: Record<string, string>): Record<string, string> {
    return {
      Authorization: `Bearer ${this.endpoint.token}`,
      ...extra,
    };
  }

  /**
   * Core request that expects the JSON envelope and returns the unwrapped
   * `data` payload, throwing DeviceApiError on an error envelope or non-2xx.
   */
  async request<T = unknown>(
    method: string,
    pathSuffix: string,
    opts: RequestOptions = {},
  ): Promise<T> {
    const url = this.buildUrl(pathSuffix, opts.query);
    const headers = this.authHeaders({
      Accept: "application/json",
      ...(opts.body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...opts.headers,
    });

    log.debug(`${method} ${url}`);

    const res = await fetch(url, {
      method,
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      signal: opts.signal,
    });

    const ct = res.headers.get("content-type") ?? "";
    let parsed: unknown = undefined;
    if (ct.includes("application/json")) {
      const raw = await res.text();
      parsed = raw.length ? JSON.parse(raw) : undefined;
    } else {
      // Non-JSON: read text so we can include it in an error if needed.
      parsed = await res.text();
    }

    if (!res.ok) {
      const envErr =
        parsed && typeof parsed === "object" && "error" in parsed
          ? (parsed as { error: DeviceError }).error
          : { code: `http_${res.status}`, message: typeof parsed === "string" ? parsed : res.statusText };
      throw new DeviceApiError(res.status, envErr);
    }

    if (parsed && typeof parsed === "object" && "error" in parsed) {
      throw new DeviceApiError(res.status, (parsed as { error: DeviceError }).error);
    }

    if (parsed && typeof parsed === "object" && "data" in parsed) {
      return (parsed as { data: T }).data;
    }

    // Body had no envelope (shouldn't happen for v1 endpoints) — return as-is.
    return parsed as T;
  }

  get<T = unknown>(pathSuffix: string, query?: Query, opts: RequestOptions = {}): Promise<T> {
    return this.request<T>("GET", pathSuffix, { ...opts, query });
  }

  post<T = unknown>(pathSuffix: string, body?: unknown, opts: RequestOptions = {}): Promise<T> {
    return this.request<T>("POST", pathSuffix, { ...opts, body });
  }

  put<T = unknown>(pathSuffix: string, body?: unknown, opts: RequestOptions = {}): Promise<T> {
    return this.request<T>("PUT", pathSuffix, { ...opts, body });
  }

  del<T = unknown>(pathSuffix: string, query?: Query, opts: RequestOptions = {}): Promise<T> {
    return this.request<T>("DELETE", pathSuffix, { ...opts, query });
  }

  /**
   * Fetch a raw (possibly large, possibly binary) body — e.g. /net file bodies
   * or /fs file content. Inlines text only when within MAX_INLINE_BYTES.
   */
  async fetchBody(pathSuffix: string, query?: Query, opts: RequestOptions = {}): Promise<BodyResult> {
    const url = this.buildUrl(pathSuffix, query);
    const headers = this.authHeaders(opts.headers);
    log.debug(`GET (raw) ${url}`);
    const res = await fetch(url, { method: "GET", headers, signal: opts.signal });

    const contentType = res.headers.get("content-type");

    if (!res.ok) {
      const raw = await res.text();
      let envErr: DeviceError;
      try {
        const j = JSON.parse(raw) as { error?: DeviceError };
        envErr = j.error ?? { code: `http_${res.status}`, message: res.statusText };
      } catch {
        envErr = { code: `http_${res.status}`, message: raw || res.statusText };
      }
      throw new DeviceApiError(res.status, envErr);
    }

    const buf = Buffer.from(await res.arrayBuffer());
    const byteLength = buf.byteLength;

    if (byteLength > MAX_INLINE_BYTES) {
      return {
        byteLength,
        contentType,
        truncated: true,
        note:
          `Body is ${byteLength} bytes (> ${MAX_INLINE_BYTES} inline cap) and was not inlined. ` +
          `Read it via the corresponding sandbox:// resource or re-request a byte range.`,
      };
    }

    const looksBinary =
      contentType !== null &&
      !/^(text\/|application\/(json|xml|javascript|x-www-form-urlencoded))/i.test(contentType);

    if (looksBinary) {
      return {
        byteLength,
        contentType,
        truncated: true,
        note: `Binary body (${contentType ?? "unknown"}, ${byteLength} bytes) not inlined as text.`,
      };
    }

    return {
      text: buf.toString("utf8"),
      byteLength,
      contentType,
      truncated: false,
    };
  }

  // ---- typed helpers --------------------------------------------------------

  healthz(): Promise<HealthzData> {
    return this.get<HealthzData>("/healthz");
  }

  plugins(): Promise<PluginsData> {
    return this.get<PluginsData>("/plugins");
  }
}
