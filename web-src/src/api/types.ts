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
  // Richer host/app identity (additive; present on recent device builds).
  appName?: string;
  appVersion?: string; // CFBundleShortVersionString
  appBuild?: string; // CFBundleVersion
  sdkVersion?: string;
  osName?: string;
  osVersion?: string;
  deviceModel?: string;
  appIcon?: string; // base64 PNG (iOS only)
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
  limitations?: string[]; // coverage caveats, e.g. network capture blind spots
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

// --- Bundle plugin (App Bundle / IPA payload inspector) ---

export interface BundleSummary {
  supported: boolean;
  bundleId?: string;
  bundlePath?: string;
  displayName?: string;
  shortVersion?: string;
  build?: string;
  minimumOSVersion?: string;
  platform?: string;
  deviceFamilies: string[];
  sdkName?: string;
  icon?: string; // base64 PNG
}

export interface MachOSlice {
  cpuType: string;
  cpuSubtype: string;
  is64: boolean;
  magic: string;
  encrypted: boolean;
  cryptId?: number | null;
  fileType?: string | null;
}

export interface MachOInfo {
  supported: boolean;
  executablePath?: string;
  fileSize: number;
  fat: boolean;
  slices: MachOSlice[];
}

export interface Provisioning {
  present: boolean;
  name?: string;
  teamIdentifier?: string;
  teamName?: string;
  appIdName?: string;
  appId?: string;
  creationDate?: number; // unix seconds
  expirationDate?: number;
  expired?: boolean;
  provisionedDeviceCount?: number;
  isDistribution?: boolean;
  entitlements?: unknown;
  parseError?: string;
}

export interface UsageDescription {
  key: string;
  purpose: string;
}

export interface ATSInfo {
  allowsArbitraryLoads: boolean;
  exceptionDomains: string[];
}

export interface BundlePrivacy {
  usageDescriptions: UsageDescription[];
  urlSchemes: string[];
  backgroundModes: string[];
  ats?: ATSInfo | null;
}

export interface PlistDecode {
  path: string;
  format: string; // binary | xml | openstep
  json: unknown;
}

// --- Files plugin ---

export interface FileEntry {
  name: string;
  path: string;
  isDir: boolean;
  size: number;
  mtime: number; // unix milliseconds
  mime: string;
}

export interface DirListing {
  path: string;
  items: FileEntry[];
  nextCursor: string | null;
}

export interface FsRoot {
  name: string;
  path: string;
  readOnly?: boolean; // e.g. the OS-mounted .app bundle — writes/deletes are refused
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

export interface DbTable {
  name: string;
  rowCount: number | null; // null until requested (?counts=true); -1 if the count query failed
}

export interface DbColumn {
  name: string;
  type: string;
  pk: boolean;
  notnull: boolean;
}

export interface DbForeignKey {
  from: string;
  table: string;
  to: string;
}

export interface DbSchema {
  columns: DbColumn[];
  foreignKeys: DbForeignKey[];
}

export type DbCell = string | number | boolean | null;

export interface DbQueryResult {
  columns: string[];
  rows: DbCell[][];
  nextCursor: string | null;
}

// --- Logs plugin ---

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  seq: number;
  ts: number; // unix milliseconds
  level: LogLevel | string;
  message: string;
  source: string; // sdk | stdout | stderr | app
  category: string | null;
}

// --- Screen plugin ---

export interface ScreenInfo {
  supported: boolean;
  width: number; // window points
  height: number;
  scale: number;
  gestures: boolean; // real swipe/drag available (private touch injection)
}

export interface ScreenAction {
  ok: boolean;
  detail: string;
}

// --- Hierarchy plugin ---

export interface HierarchyNode {
  id: number;
  cls: string;
  depth: number;
  x: number;
  y: number;
  w: number;
  h: number;
  alpha: number;
  hidden: boolean;
  label: string | null;
  bg: string | null;
  thumb: string | null; // base64 PNG of the view's own content (leaf/content views), when requested
  children: HierarchyNode[];
}

export interface HierarchyTree {
  supported: boolean;
  width: number;
  height: number;
  nodeCount: number;
  truncated: boolean;
  root: HierarchyNode | null;
}

// --- Captured WebSocket traffic (the `ws` plugin) ---

export type WsConnState = 'opening' | 'open' | 'closed' | 'failed';

export interface WsConnSummary {
  id: string;
  url: string;
  host: string;
  startedAt: number;
  state: WsConnState | string;
  closedAt: number | null;
  messageCount: number;
}

export interface WsConnDetail extends WsConnSummary {
  closeReason: string | null;
  error: string | null;
}

export interface WsMsgSummary {
  id: string;
  connId: string;
  direction: 'sent' | 'received' | string;
  opcode: string; // text | binary
  preview: string | null;
  size: number;
  ts: number;
  seq: number;
}

export interface WsOpenedPayload {
  id: string;
  url: string;
  host: string;
  startedAt: number;
}

export interface WsClosedPayload {
  id: string;
  state: string;
  closedAt: number;
  closeReason?: string | null;
  error?: string | null;
}

// --- WebSocket transport (the console's own multiplexed live channel) ---

export type WsChannel = 'net' | 'logs' | 'fs' | 'db' | 'ws';

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
