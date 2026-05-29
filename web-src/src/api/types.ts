// Shared wire-contract types for the SandboxServer console.
// These mirror the frozen REST/WS shapes exactly.

export interface ApiMeta {
  apiVersion: string;
  ts: number;
}

export interface ApiError {
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

export interface SuccessEnvelope<T> {
  data: T;
  meta: ApiMeta;
}

export interface ErrorEnvelope {
  error: ApiError;
}

export interface ListPayload<T> {
  items: T[];
  nextCursor: string | null;
}

// --- Meta ---

export type BindingPolicy = 'loopback' | 'localNetwork';

export interface Health {
  apiVersion: string;
  buildConfig: string; // expected "debug"
  deviceName: string;
  appBundleId: string;
  bindingPolicy: BindingPolicy;
  requiresAuth: boolean;
}

export interface McpTool {
  name: string;
  title: string;
  description: string;
  readOnlyHint: boolean;
  destructiveHint: boolean;
  backingMethod: string;
  backingPathSuffix: string;
}

export interface Plugin {
  id: 'fs' | 'db' | 'net' | string;
  version: string;
  title: string;
  panelKey: string;
  routes: string[];
  channels: string[];
  mcpTools: McpTool[];
}

// --- Network plugin ---

export type StatusClass = '1xx' | '2xx' | '3xx' | '4xx' | '5xx';

export interface NetRequestSummary {
  id: string;
  method: string;
  url: string;
  status: number | null;
  startedAt: number;
  durationMs: number | null;
  reqBytes: number | null;
  respBytes: number | null;
}

export interface NetRequestDetail extends NetRequestSummary {
  reqHeaders?: Record<string, string>;
  reqBody?: string | null;
  respHeaders?: Record<string, string>;
  respBody?: string | null;
}

// --- DB plugin ---

export type DbEngine = 'sqlite' | 'coredata' | 'realm';

export interface DbDescriptor {
  id: string;
  engine: DbEngine;
  name: string;
  path: string;
  readOnly: boolean;
}

// --- WebSocket ---

export type WsChannel = 'net' | 'log' | 'fs' | 'db';

export interface WsServerMessage<P = Record<string, unknown>> {
  channel: WsChannel;
  type: string;
  seq: number;
  payload: P;
}

export interface NetStartedPayload {
  id: string;
  method: string;
  url: string;
  startedAt: number;
}

export interface NetCompletedPayload {
  id: string;
  method: string;
  url: string;
  status: number;
  startedAt: number;
  durationMs: number;
  reqBytes: number;
  respBytes: number;
}
