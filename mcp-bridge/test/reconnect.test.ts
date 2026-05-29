import { test } from "node:test";
import assert from "node:assert/strict";
import { DeviceClient, DeviceApiError, TransportError } from "../src/deviceClient.js";
import { parseFlags, type ResolveResult } from "../src/discovery.js";
import { createSupervisor, isReconnectEnabled } from "../src/reconnect.js";

function client(host = "old", port = 1, token = "t"): DeviceClient {
  return new DeviceClient({ host, port, token });
}
const refused = () => new TransportError("connect_refused", "connection refused", "ECONNREFUSED");
const result = (host: string, port: number, token: string): ResolveResult => ({
  source: "bonjour",
  endpoint: { host, port, token },
});

// ---- gating -----------------------------------------------------------------

test("isReconnectEnabled: default on; flag and env overrides", () => {
  const prev = process.env.SANDBOX_RECONNECT;
  try {
    delete process.env.SANDBOX_RECONNECT;
    assert.equal(isReconnectEnabled({}), true);
    assert.equal(isReconnectEnabled({ reconnect: false }), false);
    assert.equal(isReconnectEnabled({ reconnect: true }), true);
    for (const v of ["0", "false", "off", "no", "OFF"]) {
      process.env.SANDBOX_RECONNECT = v;
      assert.equal(isReconnectEnabled({}), false, v);
    }
    process.env.SANDBOX_RECONNECT = "1";
    assert.equal(isReconnectEnabled({}), true);
    process.env.SANDBOX_RECONNECT = "0"; // explicit flag beats env
    assert.equal(isReconnectEnabled({ reconnect: true }), true);
  } finally {
    if (prev === undefined) delete process.env.SANDBOX_RECONNECT;
    else process.env.SANDBOX_RECONNECT = prev;
  }
});

test("parseFlags: --no-reconnect/--reconnect are boolean and do not eat the next token", () => {
  assert.equal(parseFlags(["--no-reconnect"]).reconnect, false);
  assert.equal(parseFlags(["--reconnect"]).reconnect, true);
  assert.equal(parseFlags([]).reconnect, undefined);
  // regression guard: the boolean flag must not swallow --host as its value
  assert.deepEqual(parseFlags(["--no-reconnect", "--host", "h", "--port", "5"]), {
    reconnect: false,
    host: "h",
    port: 5,
  });
});

// ---- endpoint swap ----------------------------------------------------------

test("updateEndpoint repoints buildUrl in place", () => {
  const device = client("a", 1, "t");
  assert.match(device.buildUrl("/healthz"), /^http:\/\/a:1\//);
  device.updateEndpoint({ host: "b", port: 2, token: "t2" });
  assert.match(device.buildUrl("/healthz"), /^http:\/\/b:2\//);
  assert.equal(device.endpoint.token, "t2");
});

// ---- checkOnce --------------------------------------------------------------

test("healthy device -> ok, never re-resolves", async () => {
  let resolveCalls = 0;
  const sup = createSupervisor({
    device: client(),
    flags: {},
    threshold: 1,
    ping: async () => undefined,
    resolve: async () => {
      resolveCalls++;
      return result("x", 9, "t");
    },
  });
  assert.equal(await sup.checkOnce(), "ok");
  assert.equal(resolveCalls, 0);
});

test("connectivity failure below threshold -> down, no re-resolve yet", async () => {
  const device = client("old", 1, "t");
  let resolveCalls = 0;
  const sup = createSupervisor({
    device,
    flags: {},
    threshold: 2,
    ping: async () => {
      throw refused();
    },
    resolve: async () => {
      resolveCalls++;
      return result("h2", 2, "t");
    },
  });
  assert.equal(await sup.checkOnce(), "down");
  assert.equal(resolveCalls, 0);
  assert.equal(await sup.checkOnce(), "down"); // hits threshold; resolve attempted, verify ping still fails
  assert.equal(resolveCalls, 1);
  // attemptReconnect swaps the endpoint in BEFORE the verify ping, so a FAILED verify leaves the
  // client pointed at the freshly-resolved endpoint (intentional; the next cycle re-resolves anyway).
  assert.equal(device.endpoint.host, "h2");
});

test("sustained failure then recovery -> reconnected, endpoint swapped (the A5 acceptance case)", async () => {
  const device = client("old", 1, "t");
  let resolveCalls = 0;
  const sup = createSupervisor({
    device,
    flags: {},
    threshold: 1,
    // fails for the old endpoint, succeeds once the device has been repointed to "new"
    ping: async () => {
      if (device.endpoint.host !== "new") throw refused();
    },
    resolve: async () => {
      resolveCalls++;
      return result("new", 2, "t2");
    },
  });
  assert.equal(await sup.checkOnce(), "reconnected");
  assert.equal(device.endpoint.host, "new");
  assert.equal(device.endpoint.port, 2);
  assert.equal(resolveCalls, 1);
  // subsequent check is healthy and does not re-resolve
  assert.equal(await sup.checkOnce(), "ok");
  assert.equal(resolveCalls, 1);
});

test("a device 401 (rotated token) counts as a connectivity failure and triggers re-resolve", async () => {
  const device = client("old", 1, "stale");
  const sup = createSupervisor({
    device,
    flags: {},
    threshold: 1,
    ping: async () => {
      if (device.endpoint.token !== "fresh") throw new DeviceApiError(401, { code: "unauthorized", message: "bad token" });
    },
    resolve: async () => result("old", 1, "fresh"),
  });
  assert.equal(await sup.checkOnce(), "reconnected");
  assert.equal(device.endpoint.token, "fresh");
});

test("a non-connectivity device error (404) does NOT trigger a reconnect", async () => {
  let resolveCalls = 0;
  const sup = createSupervisor({
    device: client(),
    flags: {},
    threshold: 1,
    ping: async () => {
      throw new DeviceApiError(404, { code: "not_found", message: "x" });
    },
    resolve: async () => {
      resolveCalls++;
      return result("h2", 2, "t");
    },
  });
  assert.equal(await sup.checkOnce(), "ok"); // device reachable, just unhappy
  assert.equal(resolveCalls, 0);
});

test("a re-resolve failure (no peer) -> down, never throws, endpoint untouched", async () => {
  const device = client("old", 1, "t");
  const sup = createSupervisor({
    device,
    flags: {},
    threshold: 1,
    ping: async () => {
      throw refused();
    },
    resolve: async () => {
      throw new Error("no SandboxServer peers found");
    },
  });
  assert.equal(await sup.checkOnce(), "down");
  assert.equal(device.endpoint.host, "old"); // resolve threw before updateEndpoint, so nothing swapped
});

test("re-resolve is throttled (backoff) while a device stays persistently down", async () => {
  let resolveCalls = 0;
  const sup = createSupervisor({
    device: client(),
    flags: {},
    threshold: 1,
    ping: async () => {
      throw refused();
    },
    resolve: async () => {
      resolveCalls++;
      return result("h2", 2, "t"); // verify ping still fails, so it never recovers
    },
  });
  // 20 down-cycles. Without backoff this would re-resolve (a Bonjour browse) all 20 times; the
  // geometric backoff (1,2,4,8,16…) means far fewer expensive re-resolves.
  for (let i = 0; i < 20; i++) assert.equal(await sup.checkOnce(), "down");
  assert.ok(resolveCalls < 8, `re-resolve should be throttled, got ${resolveCalls}`);
});

test("start()/stop() are idempotent", () => {
  const sup = createSupervisor({
    device: client(),
    flags: {},
    ping: async () => undefined,
    resolve: async () => result("a", 1, "t"),
  });
  sup.start();
  sup.start();
  sup.stop();
  sup.stop();
});

test("schedule() unref's the heartbeat timer so it never blocks process exit", () => {
  const real = globalThis.setTimeout;
  let unrefCalls = 0;
  globalThis.setTimeout = ((fn: () => void, ms?: number) => {
    const h = real(fn, ms);
    const origUnref = h.unref.bind(h);
    h.unref = () => {
      unrefCalls++;
      return origUnref();
    };
    return h;
  }) as typeof setTimeout;
  try {
    const sup = createSupervisor({
      device: client(),
      flags: {},
      intervalMs: 50,
      ping: async () => undefined,
      resolve: async () => result("a", 1, "t"),
    });
    sup.start();
    assert.equal(unrefCalls, 1, "the armed heartbeat timer must be unref'd");
    sup.stop();
  } finally {
    globalThis.setTimeout = real;
  }
});

test("the scheduled timer loop actually runs, recovers, and stops cleanly (the production path)", async () => {
  const device = client("old", 1, "t");
  let pings = 0;
  let onReconnect!: () => void;
  const reconnected = new Promise<void>((r) => (onReconnect = r));
  const sup = createSupervisor({
    device,
    flags: {},
    intervalMs: 1, // tiny real interval drives the actual setTimeout loop
    threshold: 1,
    ping: async () => {
      pings++;
      if (device.endpoint.host !== "new") throw refused(); // unreachable until repointed
      onReconnect();
    },
    resolve: async () => result("new", 2, "t2"),
  });
  sup.start();
  await reconnected; // proves tick() fired AND rescheduled (recovery needs >=2 cycles)
  assert.equal(device.endpoint.host, "new");
  sup.stop();
  const before = pings;
  await new Promise((r) => setTimeout(r, 15)); // several intervals
  assert.equal(pings, before, "no pings fire after stop() — the timer is cleared");
});

test("stop() during an in-flight check does not reschedule the loop", async () => {
  let release!: () => void;
  let pings = 0;
  const gate = new Promise<void>((r) => (release = r));
  const sup = createSupervisor({
    device: client(),
    flags: {},
    intervalMs: 1,
    threshold: 1,
    ping: async () => {
      pings++;
      await gate; // the first tick parks here
    },
    resolve: async () => result("x", 9, "t"),
  });
  sup.start();
  await new Promise((r) => setTimeout(r, 15)); // let the timer fire and the tick enter the awaited ping
  assert.equal(pings, 1, "one tick should be in flight");
  sup.stop(); // stop while checkOnce() is awaiting the ping
  release(); // let the in-flight check finish
  await new Promise((r) => setTimeout(r, 15));
  assert.equal(pings, 1, "no further tick after stop() during an in-flight check");
});
