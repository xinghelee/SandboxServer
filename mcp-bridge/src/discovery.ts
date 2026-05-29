/**
 * discovery — resolve the SandboxServer device endpoint.
 *
 * Precedence:
 *   1. Explicit config: env SANDBOX_HOST / SANDBOX_PORT / SANDBOX_TOKEN or
 *      CLI flags --host / --port / --token.
 *   2. Single Bonjour match: browse _sandboxserver._tcp; if exactly one peer
 *      resolves, auto-connect using its host:port + TXT record.
 *   3. Multiple peers: throw with a helpful "pin one of these" message.
 */

import Bonjour from "bonjour-service";
import type { Service } from "bonjour-service/dist/lib/service.js";
import type { Endpoint } from "./deviceClient.js";
import { log } from "./log.js";

export const SERVICE_TYPE = "sandboxserver"; // _sandboxserver._tcp
export const DEFAULT_DISCOVER_MS = 2500;

export interface CliFlags {
  host?: string;
  port?: number;
  token?: string;
  /** discovery window in ms */
  timeout?: number;
  /** explicit override of the auto-reconnect supervisor (default on) */
  reconnect?: boolean;
}

export interface DiscoveredPeer {
  name: string;
  host: string;
  port: number;
  addresses: string[];
  txt: PeerTxt;
}

export interface PeerTxt {
  ver?: string;
  apiVersion?: string;
  deviceName?: string;
  appBundleId?: string;
  requiresAuth?: boolean;
  /** token may optionally be advertised in TXT for loopback/dev convenience */
  token?: string;
  [k: string]: string | boolean | undefined;
}

/** Parse argv (after the subcommand) into typed flags. */
export function parseFlags(argv: string[]): CliFlags {
  const flags: CliFlags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const takeVal = (): string | undefined => {
      const eq = a?.indexOf("=") ?? -1;
      if (a && eq >= 0) return a.slice(eq + 1);
      const next = argv[i + 1];
      i++;
      return next;
    };
    if (!a) continue;
    if (a === "--host" || a.startsWith("--host=")) flags.host = takeVal();
    else if (a === "--port" || a.startsWith("--port=")) {
      const v = takeVal();
      if (v !== undefined) flags.port = Number(v);
    } else if (a === "--token" || a.startsWith("--token=")) flags.token = takeVal();
    else if (a === "--timeout" || a.startsWith("--timeout=")) {
      const v = takeVal();
      if (v !== undefined) flags.timeout = Number(v);
    } else if (a === "--no-reconnect") flags.reconnect = false;
    else if (a === "--reconnect") flags.reconnect = true;
  }
  return flags;
}

function explicitConfig(flags: CliFlags): { host?: string; port?: number; token?: string } {
  const host = flags.host ?? process.env.SANDBOX_HOST;
  const portRaw = flags.port ?? (process.env.SANDBOX_PORT ? Number(process.env.SANDBOX_PORT) : undefined);
  const token = flags.token ?? process.env.SANDBOX_TOKEN;
  const port = portRaw !== undefined && !Number.isNaN(portRaw) ? portRaw : undefined;
  return { host, port, token };
}

function normalizeTxt(raw: Record<string, string | true | undefined> | undefined): PeerTxt {
  const txt: PeerTxt = {};
  if (!raw) return txt;
  for (const [k, v] of Object.entries(raw)) {
    if (v === undefined) continue;
    const value = v === true ? "" : v;
    if (k === "requiresAuth") txt.requiresAuth = value === "true" || value === "1" || value === "";
    else txt[k] = value;
  }
  return txt;
}

function toPeer(svc: Service): DiscoveredPeer {
  const addresses = Array.isArray(svc.addresses) ? svc.addresses : [];
  const ipv4 = addresses.find((a) => /^\d+\.\d+\.\d+\.\d+$/.test(a));
  const host = ipv4 ?? svc.host ?? addresses[0] ?? "";
  return {
    name: svc.name ?? "unknown",
    host,
    port: svc.port,
    addresses,
    txt: normalizeTxt(svc.txt as Record<string, string | true | undefined> | undefined),
  };
}

/** Browse the LAN for SandboxServer peers for `timeoutMs`, then resolve. */
export function browse(timeoutMs = DEFAULT_DISCOVER_MS): Promise<DiscoveredPeer[]> {
  return new Promise((resolve) => {
    const bonjour = new Bonjour();
    const found = new Map<string, DiscoveredPeer>();

    const browser = bonjour.find({ type: SERVICE_TYPE }, (svc: Service) => {
      const peer = toPeer(svc);
      const key = `${peer.host}:${peer.port}:${peer.name}`;
      found.set(key, peer);
      log.debug(`mDNS peer: ${peer.name} ${peer.host}:${peer.port}`);
    });

    const finish = () => {
      try {
        browser.stop();
      } catch {
        /* ignore */
      }
      try {
        bonjour.destroy();
      } catch {
        /* ignore */
      }
      resolve([...found.values()]);
    };

    const timer = setTimeout(finish, timeoutMs);
    if (typeof timer.unref === "function") timer.unref();
  });
}

export function formatPeers(peers: DiscoveredPeer[]): string {
  if (peers.length === 0) return "(no SandboxServer peers found on the local network)";
  return peers
    .map((p, i) => {
      const d = p.txt.deviceName ? ` "${p.txt.deviceName}"` : "";
      const app = p.txt.appBundleId ? ` ${p.txt.appBundleId}` : "";
      const ver = p.txt.ver ? ` v${p.txt.ver}` : "";
      return `  [${i + 1}]${d} ${p.host}:${p.port}${app}${ver}`;
    })
    .join("\n");
}

export interface ResolveResult {
  endpoint: Endpoint;
  /** how the endpoint was resolved */
  source: "explicit" | "bonjour";
  /** the discovered peer when source === "bonjour" */
  peer?: DiscoveredPeer;
}

/**
 * Resolve the device endpoint following the documented precedence.
 * Throws with a helpful message when ambiguous or when a token is required
 * but missing.
 */
export async function resolveEndpoint(flags: CliFlags): Promise<ResolveResult> {
  const cfg = explicitConfig(flags);

  // (1) Fully explicit host+port -> no discovery needed.
  if (cfg.host && cfg.port !== undefined) {
    if (!cfg.token) {
      throw new Error(
        "Host and port were provided but no token. Set SANDBOX_TOKEN (or --token). " +
          "The device's console shows the bearer token.",
      );
    }
    return {
      source: "explicit",
      endpoint: { host: cfg.host, port: cfg.port, token: cfg.token },
    };
  }

  // (2)/(3) Bonjour discovery.
  log.info(`No explicit host:port — browsing _${SERVICE_TYPE}._tcp for ${flags.timeout ?? DEFAULT_DISCOVER_MS}ms...`);
  const peers = await browse(flags.timeout ?? DEFAULT_DISCOVER_MS);

  if (peers.length === 0) {
    throw new Error(
      "No SandboxServer device found via Bonjour and no explicit endpoint configured.\n" +
        "Set SANDBOX_HOST + SANDBOX_PORT + SANDBOX_TOKEN (or pass --host/--port/--token), " +
        "or ensure the device app is running and on the same network.",
    );
  }

  if (peers.length > 1) {
    throw new Error(
      `Multiple SandboxServer devices found (${peers.length}). Pin one explicitly via ` +
        `SANDBOX_HOST/SANDBOX_PORT (and SANDBOX_TOKEN), e.g. --host ${peers[0]!.host} --port ${peers[0]!.port}.\n` +
        `Discovered peers:\n${formatPeers(peers)}`,
    );
  }

  // Exactly one peer -> auto-connect.
  const peer = peers[0]!;
  const token = cfg.token ?? peer.txt.token;
  const requiresAuth = peer.txt.requiresAuth !== false;
  if (requiresAuth && !token) {
    throw new Error(
      `Found device${peer.txt.deviceName ? ` "${peer.txt.deviceName}"` : ""} at ${peer.host}:${peer.port}, ` +
        "but it requires auth and no token was provided. Set SANDBOX_TOKEN (or --token) from the device console.",
    );
  }

  return {
    source: "bonjour",
    peer,
    endpoint: { host: peer.host, port: peer.port, token: token ?? "" },
  };
}
