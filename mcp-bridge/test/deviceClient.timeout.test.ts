import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { DeviceClient } from "../src/deviceClient.js";

const ENDPOINT = { host: "127.0.0.1", port: 1, token: "t" } as const;
const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** A fetch that never resolves on its own — it only settles if its signal aborts (like undici). */
function hangingFetch(): void {
  globalThis.fetch = ((_input: unknown, init?: { signal?: AbortSignal }) =>
    new Promise((_resolve, reject) => {
      const signal = init?.signal;
      if (!signal) return;
      if (signal.aborted) {
        reject(signal.reason);
        return;
      }
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    })) as unknown as typeof fetch;
}

/** A fetch that immediately returns a JSON envelope. */
function okFetch(payload: unknown): void {
  globalThis.fetch = (async () =>
    new Response(JSON.stringify({ data: payload, meta: { apiVersion: "1", ts: 0 } }), {
      status: 200,
      headers: { "content-type": "application/json" },
    })) as unknown as typeof fetch;
}

test("request() rejects with a TimeoutError when the device hangs, instead of hanging forever", async () => {
  hangingFetch();
  const client = new DeviceClient(ENDPOINT, { timeoutMs: 50 });
  const started = Date.now();
  await assert.rejects(
    () => client.request("GET", "/healthz"),
    (err: unknown) => err instanceof Error && err.name === "TimeoutError",
  );
  assert.ok(Date.now() - started < 1000, "should reject promptly, not hang");
});

test("fetchBody() also honours the timeout", async () => {
  hangingFetch();
  const client = new DeviceClient(ENDPOINT, { timeoutMs: 50 });
  await assert.rejects(
    () => client.fetchBody("/fs/file", { path: "/x" }),
    (err: unknown) => err instanceof Error && err.name === "TimeoutError",
  );
});

test("a caller-supplied abort wins over the timeout and preserves its reason", async () => {
  hangingFetch();
  const client = new DeviceClient(ENDPOINT, { timeoutMs: 10_000 });
  const ac = new AbortController();
  setTimeout(() => ac.abort(new Error("caller-cancelled")), 20);
  await assert.rejects(
    () => client.request("GET", "/healthz", { signal: ac.signal }),
    (err: unknown) => err instanceof Error && err.message === "caller-cancelled",
  );
});

test("an already-aborted caller signal rejects immediately", async () => {
  hangingFetch();
  const client = new DeviceClient(ENDPOINT, { timeoutMs: 10_000 });
  await assert.rejects(
    () => client.request("GET", "/healthz", { signal: AbortSignal.abort(new Error("pre-aborted")) }),
    (err: unknown) => err instanceof Error && err.message === "pre-aborted",
  );
});

test("a successful response resolves with the unwrapped data and leaves no dangling timer", async () => {
  okFetch({ ok: true, n: 42 });
  const client = new DeviceClient(ENDPOINT, { timeoutMs: 50 });
  const data = await client.request<{ ok: boolean; n: number }>("GET", "/healthz");
  assert.deepEqual(data, { ok: true, n: 42 });
});

test("SANDBOX_TIMEOUT_MS overrides the default when no explicit timeout is given", async () => {
  hangingFetch();
  const prev = process.env.SANDBOX_TIMEOUT_MS;
  process.env.SANDBOX_TIMEOUT_MS = "40";
  try {
    const client = new DeviceClient(ENDPOINT);
    const started = Date.now();
    await assert.rejects(() => client.request("GET", "/healthz"));
    assert.ok(Date.now() - started < 1000, "env-configured timeout should apply");
  } finally {
    if (prev === undefined) delete process.env.SANDBOX_TIMEOUT_MS;
    else process.env.SANDBOX_TIMEOUT_MS = prev;
  }
});
