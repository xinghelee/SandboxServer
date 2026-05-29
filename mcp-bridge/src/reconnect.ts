/**
 * reconnect — a low-frequency supervisor that keeps a long-lived stdio session
 * working across device restarts.
 *
 * registerAll() wires tools ONCE at connect, then cmdConnect parks forever. If
 * the device restarts, its binding can change and (with auth:.token) its
 * per-start() token rotates, so every later tool call fails — historically with
 * no recovery short of relaunching the MCP client. This supervisor periodically
 * pings /healthz; after `threshold` consecutive connectivity failures it
 * re-resolves the endpoint (re-reading env/flags, re-browsing Bonjour) and swaps
 * it into the live DeviceClient IN PLACE, so the already-registered tools keep
 * working. It only ever writes to stderr (never stdout), so the JSON-RPC stream
 * is untouched.
 *
 * A connectivity failure is a TransportError (unreachable) OR a device 401 (a
 * rotated token). Other device errors (403/404/5xx) mean the device is reachable
 * and answering, so they never trigger a reconnect. A token pinned via env can't
 * be auto-refreshed by re-resolution, so a persistent 401 is reported with an
 * actionable hint rather than retried blindly.
 */

import { DeviceApiError, TransportError, type DeviceClient } from "./deviceClient.js";
import { resolveEndpoint, type CliFlags, type ResolveResult } from "./discovery.js";
import { log } from "./log.js";

export const DEFAULT_RECONNECT_INTERVAL_MS = 15_000;
export const DEFAULT_RECONNECT_PING_TIMEOUT_MS = 4_000;
export const DEFAULT_RECONNECT_THRESHOLD = 2;
/** Cap on the re-resolve backoff (in heartbeat cycles) while a device stays down. */
export const MAX_RESOLVE_BACKOFF_CYCLES = 16;

export type CheckOutcome = "ok" | "down" | "reconnected";

export interface Supervisor {
  start(): void;
  stop(): void;
  /** One health-check (+ maybe re-resolve) cycle. Exposed for deterministic tests. */
  checkOnce(): Promise<CheckOutcome>;
}

export interface SupervisorOptions {
  device: DeviceClient;
  flags: CliFlags;
  intervalMs?: number;
  pingTimeoutMs?: number;
  /** consecutive connectivity failures before a re-resolve is attempted */
  threshold?: number;
  /** test seam: defaults to device.healthz({ timeoutMs }) */
  ping?: (timeoutMs: number) => Promise<unknown>;
  /** test seam: defaults to resolveEndpoint(flags) */
  resolve?: () => Promise<ResolveResult>;
}

/** Reconnect is ON by default; disable with --no-reconnect or SANDBOX_RECONNECT in {0,false,off,no}. */
export function isReconnectEnabled(flags: { reconnect?: boolean }): boolean {
  if (typeof flags.reconnect === "boolean") return flags.reconnect;
  const env = process.env.SANDBOX_RECONNECT?.trim().toLowerCase();
  if (env && ["0", "false", "off", "no"].includes(env)) return false;
  return true;
}

function isConnectivityFailure(err: unknown): boolean {
  // Unreachable, OR the device answered 401 (token rotated on restart).
  return err instanceof TransportError || (err instanceof DeviceApiError && err.status === 401);
}

function msg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export function createSupervisor(opts: SupervisorOptions): Supervisor {
  const intervalMs = opts.intervalMs ?? DEFAULT_RECONNECT_INTERVAL_MS;
  const pingTimeoutMs = opts.pingTimeoutMs ?? DEFAULT_RECONNECT_PING_TIMEOUT_MS;
  const threshold = Math.max(1, opts.threshold ?? DEFAULT_RECONNECT_THRESHOLD);
  const ping = opts.ping ?? ((t: number) => opts.device.healthz({ timeoutMs: t }));
  const resolve = opts.resolve ?? (() => resolveEndpoint(opts.flags));

  let failures = 0;
  // `nextResolveAt`/`backoff` throttle the EXPENSIVE re-resolve (a ~2.5s Bonjour browse) while a
  // device stays down, so we don't browse + warn every interval forever. The cheap per-interval
  // ping still runs every cycle, so a device coming back at the SAME endpoint recovers immediately.
  let nextResolveAt = threshold;
  let backoff = threshold;
  // Dedup the "still down" warning: log once per distinct failure state, debug for the repeats.
  let warnedKey: string | undefined;
  let running = false;
  let inFlight = false;
  let timer: ReturnType<typeof setTimeout> | undefined;

  function resetDownState(): void {
    failures = 0;
    nextResolveAt = threshold;
    backoff = threshold;
    warnedKey = undefined;
  }

  async function attemptReconnect(): Promise<CheckOutcome> {
    try {
      const r = await resolve();
      opts.device.updateEndpoint(r.endpoint);
      await ping(pingTimeoutMs); // verify the swapped endpoint actually answers
      log.banner(`sandbox-mcp reconnected -> ${r.endpoint.host}:${r.endpoint.port} (${r.source})`);
      resetDownState();
      return "reconnected";
    } catch (err) {
      // A pinned token can't be refreshed by re-resolution; surface that ONCE, not every cycle.
      const tokenRotated = err instanceof DeviceApiError && err.status === 401;
      const key = tokenRotated ? "token" : "fail";
      if (key !== warnedKey) {
        warnedKey = key;
        if (tokenRotated) {
          log.warn(
            "reconnect: device rejected the token (it likely rotated on restart). " +
              "Set SANDBOX_TOKEN to the current console token, then reconnect.",
          );
        } else {
          log.warn(`reconnect attempt failed: ${msg(err)} — will keep retrying with backoff.`);
        }
      } else {
        log.debug(`reconnect still failing (${key}): ${msg(err)}`);
      }
      return "down";
    }
  }

  async function checkOnce(): Promise<CheckOutcome> {
    try {
      await ping(pingTimeoutMs);
      if (failures > 0) log.info("device reachable again.");
      resetDownState();
      return "ok";
    } catch (err) {
      if (!isConnectivityFailure(err)) {
        // Device answered with a non-connectivity error — it's reachable; reconnect won't help.
        log.debug(`health check: device reachable but errored (${msg(err)})`);
        resetDownState();
        return "ok";
      }
      failures++;
      log.debug(`device health check failed (${failures}): ${msg(err)}`);
      if (failures < nextResolveAt) return "down";
      const outcome = await attemptReconnect();
      if (outcome === "reconnected") return outcome;
      // Failed to recover: grow the gap before the next (expensive) re-resolve.
      backoff = Math.min(backoff * 2, MAX_RESOLVE_BACKOFF_CYCLES);
      nextResolveAt = failures + backoff;
      return "down";
    }
  }

  function schedule(): void {
    // Clear any existing timer first so a re-entrant schedule() can never orphan/multiply timers.
    if (timer) {
      clearTimeout(timer);
      timer = undefined;
    }
    if (!running) return;
    timer = setTimeout(() => {
      void tick();
    }, intervalMs);
    // Never keep the process alive just for the heartbeat.
    timer.unref();
  }

  async function tick(): Promise<void> {
    if (inFlight) {
      schedule();
      return;
    }
    inFlight = true;
    try {
      await checkOnce();
    } catch {
      /* checkOnce never throws, but never let the loop die regardless */
    } finally {
      inFlight = false;
      schedule();
    }
  }

  return {
    start() {
      if (running) return;
      running = true;
      schedule();
    },
    stop() {
      running = false;
      if (timer) clearTimeout(timer);
      timer = undefined;
      // Reset so a later start() behaves like a fresh run (no carried-over inFlight/failures).
      inFlight = false;
      resetDownState();
    },
    checkOnce,
  };
}
