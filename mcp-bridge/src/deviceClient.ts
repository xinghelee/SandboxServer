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

/** Default per-request timeout (ms); override with the SANDBOX_TIMEOUT_MS env var. */
export const DEFAULT_TIMEOUT_MS = 10_000;

/** Shorter timeout for the startup/probe healthz so a missing device fails fast. */
export const HEALTHZ_TIMEOUT_MS = 5_000;

function envTimeout(fallback: number): number {
  const raw = process.env.SANDBOX_TIMEOUT_MS;
  if (raw === undefined) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

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

/**
 * Thrown when the request never got an answer from the device — a connection
 * failure, a DNS failure, our own timeout, or a caller abort. Distinct from
 * DeviceApiError (the device answered with a non-2xx). `reason` is an internal
 * sub-discriminator used only for hint precision; the consumer-facing taxonomy
 * collapses every TransportError to the single kind "unreachable".
 */
export class TransportError extends Error {
  readonly reason:
    | "timeout"
    | "aborted"
    | "connect_refused"
    | "dns"
    | "reset"
    | "host_unreachable"
    | "network";
  /** Raw underlying code when known (ECONNREFUSED, ENOTFOUND, ETIMEDOUT, …). */
  readonly code?: string;

  constructor(reason: TransportError["reason"], message: string, code?: string, cause?: unknown) {
    super(message, cause !== undefined ? { cause } : undefined); // Error.cause: Node >=18
    this.name = "TransportError";
    this.reason = reason;
    this.code = code;
  }
}

/** Read a Node SystemError code off `err.cause` defensively (it may be absent, primitive, or throw). */
function readCauseCode(err: unknown): string | undefined {
  try {
    const c = (err as { cause?: unknown }).cause;
    if (c && typeof c === "object") {
      const code = (c as { code?: unknown }).code;
      if (typeof code === "string") return code;
      // happy-eyeballs / dual-stack failures wrap an AggregateError; peek one level.
      const errs = (c as { errors?: unknown }).errors;
      if (Array.isArray(errs) && errs[0] && typeof errs[0] === "object") {
        const ic = (errs[0] as { code?: unknown }).code;
        if (typeof ic === "string") return ic;
      }
    }
  } catch {
    /* a throwing getter on cause — fall through */
  }
  return undefined;
}

function reasonForCode(code: string | undefined): TransportError["reason"] {
  switch (code) {
    case "ECONNREFUSED":
      return "connect_refused";
    case "ENOTFOUND":
    case "EAI_AGAIN":
      return "dns";
    case "ECONNRESET":
      return "reset";
    case "ETIMEDOUT":
      return "timeout";
    case "EHOSTUNREACH":
    case "ENETUNREACH":
      return "host_unreachable";
    default:
      return "network"; // incl. UND_ERR_SOCKET and undefined
  }
}

/**
 * Convert a thrown value into a TransportError, or return null to rethrow it
 * unchanged. Detection ORDER is load-bearing: the name-based DOMException checks
 * (TimeoutError, then AbortError) MUST precede the `TypeError('fetch failed')`
 * branch, because those abort DOMExceptions are NOT instanceof TypeError.
 */
export function toTransportError(err: unknown, host: string, port: number): TransportError | null {
  if (err instanceof DeviceApiError) return null; // device answered → protocol case
  if (err instanceof TransportError) return err; // idempotent

  const name = (err as { name?: unknown })?.name;
  // (1) our deadline() timeout — a DOMException named TimeoutError, re-thrown verbatim by fetch.
  if (name === "TimeoutError") {
    return new TransportError("timeout", err instanceof Error ? err.message : "request timed out", "ETIMEDOUT", err);
  }
  // (2) a caller abort with the default/empty reason → AbortError DOMException.
  if (name === "AbortError") {
    return new TransportError(
      "aborted",
      err instanceof Error && err.message ? err.message : "request aborted",
      undefined,
      err,
    );
  }
  // (3) an undici network failure. Must be after the name checks above.
  if (err instanceof TypeError && /fetch failed/i.test(err.message)) {
    const code = readCauseCode(err);
    return new TransportError(
      reasonForCode(code),
      `cannot reach ${host}:${port}` + (code ? ` (${code})` : ""),
      code,
      err,
    );
  }
  // (4) anything else (a caller's custom abort reason, a JSON.parse SyntaxError, a bug) — not transport.
  return null;
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
  /** Per-call timeout override (ms). Falls back to the client default. */
  timeoutMs?: number;
}

export class DeviceClient {
  readonly endpoint: Endpoint;
  private readonly base: string;
  private readonly timeoutMs: number;

  constructor(endpoint: Endpoint, options: { timeoutMs?: number } = {}) {
    this.endpoint = endpoint;
    const scheme = endpoint.scheme ?? "http";
    this.base = `${scheme}://${endpoint.host}:${endpoint.port}`;
    this.timeoutMs = options.timeoutMs ?? envTimeout(DEFAULT_TIMEOUT_MS);
  }

  /**
   * Compose an abort signal that fires on either the caller's signal or a
   * timeout, whichever comes first. Hand-rolled rather than using
   * `AbortSignal.any` (Node 20.3+) because package.json declares `node >=18`.
   * `done()` MUST be called (in a finally) to clear the timer and detach the
   * listener, so a completed request never leaks a pending timeout.
   */
  private deadline(
    callerSignal: AbortSignal | undefined,
    timeoutMs: number,
  ): { signal: AbortSignal; done: () => void } {
    const ctrl = new AbortController();
    const onAbort = () => ctrl.abort(callerSignal?.reason);

    if (callerSignal) {
      if (callerSignal.aborted) ctrl.abort(callerSignal.reason);
      else callerSignal.addEventListener("abort", onAbort, { once: true });
    }

    const timer = setTimeout(() => {
      ctrl.abort(
        new DOMException(
          `Request to ${this.endpoint.host}:${this.endpoint.port} timed out after ${timeoutMs}ms`,
          "TimeoutError",
        ),
      );
    }, timeoutMs);
    // Never let a pending timeout keep the process alive on its own.
    timer.unref();

    const done = () => {
      clearTimeout(timer);
      callerSignal?.removeEventListener("abort", onAbort);
    };

    return { signal: ctrl.signal, done };
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

    const { signal, done } = this.deadline(opts.signal, opts.timeoutMs ?? this.timeoutMs);
    try {
      const res = await fetch(url, {
        method,
        headers,
        body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
        signal,
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
    } catch (err) {
      // This catch MUST enclose the body reads above, so a timeout firing during a slow
      // read is classified too (not leaked as an unclassified Error). A DeviceApiError
      // (non-2xx) returns null from toTransportError and is rethrown as the device case.
      const te = toTransportError(err, this.endpoint.host, this.endpoint.port);
      if (te) throw te;
      throw err;
    } finally {
      done();
    }
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

    const { signal, done } = this.deadline(opts.signal, opts.timeoutMs ?? this.timeoutMs);
    try {
      const res = await fetch(url, { method: "GET", headers, signal });

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
    } catch (err) {
      // Must enclose the arrayBuffer() read above (see request()).
      const te = toTransportError(err, this.endpoint.host, this.endpoint.port);
      if (te) throw te;
      throw err;
    } finally {
      done();
    }
  }

  // ---- typed helpers --------------------------------------------------------

  healthz(opts: RequestOptions = {}): Promise<HealthzData> {
    return this.get<HealthzData>("/healthz", undefined, opts);
  }

  plugins(): Promise<PluginsData> {
    return this.get<PluginsData>("/plugins");
  }
}
