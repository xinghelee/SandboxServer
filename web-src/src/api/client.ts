// Thin fetch wrapper around the REST API.
// - prefixes /__sandbox/api/v1
// - attaches Authorization: Bearer <token>
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

  const res = await fetch(buildUrl(path, opts.query), {
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

  databases(signal?: AbortSignal): Promise<ListPayload<DbDescriptor>> {
    return request<ListPayload<DbDescriptor>>('/db', { signal });
  },
};
