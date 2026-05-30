// Thin fetch wrapper around the REST API.
// - prefixes /__sandbox/api/v1
// - attaches the session token as Authorization and query auth
// - unwraps the { data, meta } success envelope
// - throws ApiRequestError carrying the { error } envelope on failure

import { getToken } from './auth';
import type {
  SuccessEnvelope,
  ErrorEnvelope,
  ApiError,
  Health,
  Plugin,
  ListPayload,
  NetRequestSummary,
  NetRequestDetail,
  DbDescriptor,
  DbTable,
  DbSchema,
  DbQueryResult,
  DirListing,
  FsRoot,
  LogEntry,
  ScreenInfo,
  ScreenAction,
  HierarchyTree,
  WsConnSummary,
  WsConnDetail,
  WsMsgSummary,
  BundleSummary,
  MachOInfo,
  Provisioning,
  BundlePrivacy,
  PlistDecode,
  SecurityReport,
  PerfSample,
} from './types';

export const API_PREFIX = '/__sandbox/api/v1';

export class ApiRequestError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details: Record<string, unknown> | undefined;

  constructor(status: number, error: ApiError) {
    super(error.message || error.code || `HTTP ${status}`);
    this.name = 'ApiRequestError';
    this.status = status;
    this.code = error.code;
    this.details = error.details;
  }

  get isNotImplemented(): boolean {
    return this.status === 501 || this.code === 'not_implemented';
  }

  get isUnauthorized(): boolean {
    return this.status === 401;
  }
}

interface RequestOptions {
  method?: string;
  query?: Record<string, string | number | boolean | undefined | null>;
  body?: unknown;
  signal?: AbortSignal;
}

function buildUrl(path: string, query?: RequestOptions['query']): string {
  const base = path.startsWith('/') ? `${API_PREFIX}${path}` : `${API_PREFIX}/${path}`;
  if (!query) return base;
  const usp = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v !== undefined && v !== null && v !== '') usp.set(k, String(v));
  }
  const qs = usp.toString();
  return qs ? `${base}?${qs}` : base;
}

function authQuery(query: RequestOptions['query'], token: string | null): RequestOptions['query'] {
  return token ? { ...query, token } : query;
}

export async function request<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {
    Accept: 'application/json',
  };
  if (token) headers['Authorization'] = `Bearer ${token}`;

  let body: BodyInit | undefined;
  if (opts.body !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(opts.body);
  }

  const res = await fetch(buildUrl(path, authQuery(opts.query, token)), {
    method: opts.method || 'GET',
    headers,
    body,
    signal: opts.signal,
  });

  // No content.
  if (res.status === 204) return undefined as T;

  let json: unknown = null;
  const text = await res.text();
  if (text) {
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
  }

  if (!res.ok) {
    const errEnv = json as ErrorEnvelope | null;
    const apiError: ApiError = errEnv?.error ?? {
      code: `http_${res.status}`,
      message: res.statusText || `Request failed (${res.status})`,
    };
    throw new ApiRequestError(res.status, apiError);
  }

  const env = json as SuccessEnvelope<T> | null;
  // Tolerate bare payloads but prefer the documented envelope.
  if (env && typeof env === 'object' && 'data' in env) return env.data;
  return json as T;
}

/** Raw fetch (no envelope unwrap) for binary/streamed endpoints like file reads. */
export async function rawRequest(
  path: string,
  query?: RequestOptions['query'],
  signal?: AbortSignal,
): Promise<Response> {
  const token = getToken();
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(buildUrl(path, authQuery(query, token)), { headers, signal });
  if (!res.ok) {
    let apiError: ApiError = {
      code: `http_${res.status}`,
      message: res.statusText || `Request failed (${res.status})`,
    };
    try {
      const j = JSON.parse(await res.text()) as ErrorEnvelope;
      if (j?.error) apiError = j.error;
    } catch {
      /* non-JSON error body */
    }
    throw new ApiRequestError(res.status, apiError);
  }
  return res;
}

// --- Typed endpoint helpers ---

export const api = {
  health(signal?: AbortSignal): Promise<Health> {
    return request<Health>('/healthz', { signal });
  },

  plugins(signal?: AbortSignal): Promise<ListPayload<Plugin>> {
    return request<ListPayload<Plugin>>('/plugins', { signal });
  },

  netRequests(
    query: {
      cursor?: string;
      limit?: number;
      method?: string;
      host?: string;
      statusClass?: string;
      since?: number;
    } = {},
    signal?: AbortSignal,
  ): Promise<ListPayload<NetRequestSummary>> {
    return request<ListPayload<NetRequestSummary>>('/net/requests', { query, signal });
  },

  netRequestDetail(id: string, signal?: AbortSignal): Promise<NetRequestDetail> {
    return request<NetRequestDetail>(`/net/requests/${encodeURIComponent(id)}`, {
      query: { include: 'reqHeaders,reqBody,respHeaders,respBody' },
      signal,
    });
  },

  clearNetRequests(signal?: AbortSignal): Promise<{ cleared: number }> {
    return request<{ cleared: number }>('/net/requests', { method: 'DELETE', signal });
  },

  /**
   * Re-issue a captured request, recording the result as a NEW transaction (returned as the detail).
   * Overrides are optional: `method` / `url` replace the target request line, `headers` MERGE onto the original (only changed keys; original auth is
   * kept unless overridden), and `body` is a base64 string that fully replaces the body. Send no
   * overrides (`{}`) to replay faithfully — the device keeps the full original body even though the
   * console only ever saw a (possibly truncated) preview.
   */
  netReplay(
    id: string,
    overrides: { method?: string; url?: string; headers?: Record<string, string>; body?: string } = {},
    signal?: AbortSignal,
  ): Promise<NetRequestDetail> {
    return request<NetRequestDetail>(`/net/requests/${encodeURIComponent(id)}/replay`, {
      method: 'POST',
      body: overrides,
      signal,
    });
  },

  databases(signal?: AbortSignal): Promise<ListPayload<DbDescriptor>> {
    return request<ListPayload<DbDescriptor>>('/db', { signal });
  },

  dbTables(
    dbId: string,
    signal?: AbortSignal,
    opts?: { counts?: boolean },
  ): Promise<ListPayload<DbTable>> {
    const qs = opts?.counts ? '?counts=true' : '';
    return request<ListPayload<DbTable>>(`/db/${encodeURIComponent(dbId)}/tables${qs}`, { signal });
  },

  dbSchema(dbId: string, table: string, signal?: AbortSignal): Promise<DbSchema> {
    return request<DbSchema>(
      `/db/${encodeURIComponent(dbId)}/tables/${encodeURIComponent(table)}/schema`,
      { signal },
    );
  },

  dbQuery(
    dbId: string,
    body: { sql?: string; table?: string; limit?: number; cursor?: string },
    signal?: AbortSignal,
  ): Promise<DbQueryResult> {
    return request<DbQueryResult>(`/db/${encodeURIComponent(dbId)}/query`, {
      method: 'POST',
      body,
      signal,
    });
  },

  // --- Files ---

  fsRoots(signal?: AbortSignal): Promise<ListPayload<FsRoot>> {
    return request<ListPayload<FsRoot>>('/fs/roots', { signal });
  },

  fsList(path: string, signal?: AbortSignal): Promise<DirListing> {
    return request<DirListing>('/fs/list', { query: { path }, signal });
  },

  fsRead(path: string, signal?: AbortSignal): Promise<Response> {
    return rawRequest('/fs/file', { path }, signal);
  },

  fsWrite(path: string, content: string, encoding: 'utf8' | 'base64' = 'utf8'): Promise<{ path: string; size: number }> {
    return request<{ path: string; size: number }>('/fs/file', {
      method: 'PUT',
      query: { path },
      body: { content, encoding },
    });
  },

  fsDelete(path: string, recursive = false): Promise<{ deleted: boolean }> {
    return request<{ deleted: boolean }>('/fs/file', {
      method: 'DELETE',
      query: { path, recursive: recursive ? 'true' : undefined },
    });
  },

  // --- Logs ---

  logs(
    query: { level?: string; q?: string; sinceSeq?: number; limit?: number } = {},
    signal?: AbortSignal,
  ): Promise<ListPayload<LogEntry>> {
    return request<ListPayload<LogEntry>>('/logs', { query, signal });
  },

  clearLogs(signal?: AbortSignal): Promise<{ cleared: number }> {
    return request<{ cleared: number }>('/logs', { method: 'DELETE', signal });
  },

  // --- Captured WebSocket traffic ---

  wsConnections(signal?: AbortSignal): Promise<ListPayload<WsConnSummary>> {
    return request<ListPayload<WsConnSummary>>('/ws/connections', { signal });
  },

  wsConnectionDetail(id: string, signal?: AbortSignal): Promise<WsConnDetail> {
    return request<WsConnDetail>(`/ws/connections/${encodeURIComponent(id)}`, { signal });
  },

  wsMessages(connId: string, signal?: AbortSignal): Promise<ListPayload<WsMsgSummary>> {
    return request<ListPayload<WsMsgSummary>>(
      `/ws/connections/${encodeURIComponent(connId)}/messages`,
      { signal },
    );
  },

  clearWsConnections(signal?: AbortSignal): Promise<{ cleared: number }> {
    return request<{ cleared: number }>('/ws/connections', { method: 'DELETE', signal });
  },

  // --- Screen (live mirror + control) ---

  screenInfo(signal?: AbortSignal): Promise<ScreenInfo> {
    return request<ScreenInfo>('/screen', { signal });
  },

  /** Raw JPEG frame for the live mirror; `t` busts the browser cache each poll. */
  screenFrame(maxWidth: number, quality: number, signal?: AbortSignal): Promise<Response> {
    return rawRequest('/screen/frame', { maxWidth, quality, t: Date.now() }, signal);
  },

  screenTap(x: number, y: number): Promise<ScreenAction> {
    return request<ScreenAction>('/screen/tap', { method: 'POST', body: { x, y } });
  },

  screenSwipe(from: { x: number; y: number }, to: { x: number; y: number }, duration: number): Promise<ScreenAction> {
    return request<ScreenAction>('/screen/swipe', { method: 'POST', body: { from, to, duration } });
  },

  screenType(text: string, clear = false): Promise<ScreenAction> {
    return request<ScreenAction>('/screen/text', { method: 'POST', body: { text, clear } });
  },

  screenPaste(text: string): Promise<ScreenAction> {
    return request<ScreenAction>('/screen/paste', { method: 'POST', body: { text } });
  },

  // --- App bundle / IPA payload inspector ---

  bundleSummary(signal?: AbortSignal): Promise<BundleSummary> {
    return request<BundleSummary>('/bundle', { signal });
  },

  bundleMacho(signal?: AbortSignal): Promise<MachOInfo> {
    return request<MachOInfo>('/bundle/macho', { signal });
  },

  bundleSecurity(signal?: AbortSignal): Promise<SecurityReport> {
    return request<SecurityReport>('/bundle/security', { signal });
  },

  bundleProvisioning(signal?: AbortSignal): Promise<Provisioning> {
    return request<Provisioning>('/bundle/provisioning', { signal });
  },

  bundlePrivacy(signal?: AbortSignal): Promise<BundlePrivacy> {
    return request<BundlePrivacy>('/bundle/privacy', { signal });
  },

  /** Decode a binary/XML plist (or .strings) at `path` into readable JSON. */
  bundlePlist(path: string, signal?: AbortSignal): Promise<PlistDecode> {
    return request<PlistDecode>('/bundle/plist', { query: { path }, signal });
  },

  // --- View hierarchy (3D layers) ---

  hierarchy(
    opts: { maxDepth?: number; maxNodes?: number; thumbs?: boolean } = {},
    signal?: AbortSignal,
  ): Promise<HierarchyTree> {
    return request<HierarchyTree>('/hierarchy', {
      query: { maxDepth: opts.maxDepth, maxNodes: opts.maxNodes, thumbs: opts.thumbs ? 1 : undefined },
      signal,
    });
  },

  // --- Performance HUD ---

  perfSnapshot(signal?: AbortSignal): Promise<PerfSample> {
    return request<PerfSample>('/perf', { signal });
  },
};
