import { test } from "node:test";
import assert from "node:assert/strict";
import { DeviceClient, DeviceApiError, TransportError, toTransportError } from "../src/deviceClient.js";
import { classifyError, hintFor, errorResult, buildCallback } from "../src/registerTools.js";

const H = "127.0.0.1";
const P = 8080;
const ENDPOINT = { host: H, port: P, token: "t" } as const;

// ---- toTransportError: detection -------------------------------------------

test("toTransportError maps undici fetch-failed cause.code to a reason", () => {
  const cases: Array<[string, TransportError["reason"]]> = [
    ["ECONNREFUSED", "connect_refused"],
    ["ENOTFOUND", "dns"],
    ["EAI_AGAIN", "dns"],
    ["ECONNRESET", "reset"],
    ["ETIMEDOUT", "timeout"],
    ["EHOSTUNREACH", "host_unreachable"],
    ["ENETUNREACH", "host_unreachable"],
    ["UND_ERR_SOCKET", "network"],
    ["WAT_UNKNOWN", "network"],
  ];
  for (const [code, reason] of cases) {
    const te = toTransportError(Object.assign(new TypeError("fetch failed"), { cause: { code } }), H, P);
    assert.ok(te instanceof TransportError, `${code} should classify`);
    assert.equal(te.reason, reason, code);
    assert.equal(te.code, code);
  }
});

test("readCauseCode never throws on odd cause shapes (falls back to 'network')", () => {
  const odd: unknown[] = [
    new TypeError("fetch failed"),
    Object.assign(new TypeError("fetch failed"), { cause: null }),
    Object.assign(new TypeError("fetch failed"), { cause: "a string" }),
    Object.assign(new TypeError("fetch failed"), { cause: { code: 42 } }),
  ];
  for (const e of odd) {
    const te = toTransportError(e, H, P);
    assert.ok(te instanceof TransportError);
    assert.equal(te.reason, "network");
    assert.equal(te.code, undefined);
  }
  const agg = Object.assign(new TypeError("fetch failed"), { cause: { errors: [{ code: "ECONNREFUSED" }] } });
  assert.equal(toTransportError(agg, H, P)?.reason, "connect_refused");

  const throwing = new TypeError("fetch failed");
  Object.defineProperty(throwing, "cause", {
    get() {
      throw new Error("boom");
    },
  });
  assert.equal(toTransportError(throwing, H, P)?.reason, "network");
});

test("toTransportError classifies our timeout and a default abort by DOMException name", () => {
  const t = toTransportError(new DOMException("x", "TimeoutError"), H, P);
  assert.equal(t?.reason, "timeout");
  assert.equal(t?.code, "ETIMEDOUT");
  assert.equal(toTransportError(new DOMException("y", "AbortError"), H, P)?.reason, "aborted");
});

test("toTransportError returns null for non-transport errors (rethrow unchanged)", () => {
  assert.equal(toTransportError(new DeviceApiError(404, { code: "not_found", message: "x" }), H, P), null);
  assert.equal(toTransportError(new Error("caller-cancelled"), H, P), null);
  assert.equal(toTransportError(new SyntaxError("Unexpected token"), H, P), null);
  assert.equal(toTransportError("a string", H, P), null);
  const existing = new TransportError("dns", "m", "ENOTFOUND");
  assert.equal(toTransportError(existing, H, P), existing); // idempotent
});

// ---- request()/fetchBody() integration -------------------------------------

test("a non-2xx response still throws DeviceApiError, not TransportError", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = (async () =>
    new Response(JSON.stringify({ error: { code: "not_found", message: "nope" } }), {
      status: 404,
      headers: { "content-type": "application/json" },
    })) as unknown as typeof fetch;
  try {
    const client = new DeviceClient(ENDPOINT, { timeoutMs: 1000 });
    await assert.rejects(
      () => client.request("GET", "/x"),
      (e: unknown) => e instanceof DeviceApiError && e.status === 404,
    );
  } finally {
    globalThis.fetch = original;
  }
});

test("a timeout firing DURING the body read is still classified (catch spans the read)", async () => {
  const original = globalThis.fetch;
  const rejectingBody = () => Promise.reject(new DOMException("read timed out", "TimeoutError"));
  globalThis.fetch = (async () =>
    ({
      ok: true,
      status: 200,
      headers: { get: (h: string) => (h.toLowerCase() === "content-type" ? "application/json" : null) },
      text: rejectingBody,
      arrayBuffer: rejectingBody,
    }) as unknown as Response) as unknown as typeof fetch;
  try {
    const client = new DeviceClient(ENDPOINT, { timeoutMs: 10_000 });
    await assert.rejects(
      () => client.request("GET", "/x"),
      (e: unknown) => e instanceof TransportError && e.reason === "timeout",
    );
    await assert.rejects(
      () => client.fetchBody("/x"),
      (e: unknown) => e instanceof TransportError && e.reason === "timeout",
    );
  } finally {
    globalThis.fetch = original;
  }
});

// ---- classifyError / hintFor / errorResult ---------------------------------

test("classifyError maps to device / unreachable / input", () => {
  for (const status of [400, 401, 403, 404, 501, 503]) {
    const c = classifyError(new DeviceApiError(status, { code: "x", message: "m" }));
    assert.equal(c.kind, "device");
    assert.equal(c.status, status);
    assert.equal(c.code, "x");
  }
  const u = classifyError(new TransportError("timeout", "t", "ETIMEDOUT"));
  assert.equal(u.kind, "unreachable");
  assert.equal(u.code, "ETIMEDOUT");
  assert.equal(u.reason, "timeout");
  assert.equal(classifyError(new TransportError("connect_refused", "c", "ECONNREFUSED")).kind, "unreachable");
  assert.equal(classifyError(new Error('Missing path parameter "path"')).kind, "input");
  const raw = classifyError("raw string");
  assert.equal(raw.kind, "input");
  assert.equal(raw.message, "raw string");
});

test("hintFor gives a distinct sentence per device status and unreachable reason", () => {
  const dev = (status: number) => hintFor({ kind: "device", status, message: "" });
  assert.match(dev(401), /token/i);
  assert.match(dev(403), /forbidden/i);
  assert.match(dev(404), /not found/i);
  assert.match(dev(400), /reject/i);
  assert.match(dev(501), /not implemented/i);
  assert.match(dev(503), /internal error/i);
  const un = (reason: string) => hintFor({ kind: "unreachable", reason, message: "" });
  assert.notEqual(un("timeout"), un("connect_refused"));
  assert.match(un("connect_refused"), /refused/i);
  assert.match(un("dns"), /resolve/i);
  assert.match(hintFor({ kind: "input", message: "" }), /argument/i);
});

test("errorResult shapes a nested {error} envelope per kind with isError", () => {
  const dev = errorResult(new DeviceApiError(403, { code: "forbidden", message: "nope" }), "fs_read_file");
  assert.equal(dev.isError, true);
  const de = (dev.structuredContent as { error: Record<string, unknown> }).error;
  assert.equal(de.kind, "device");
  assert.equal(de.status, 403);
  assert.equal(de.code, "forbidden");
  assert.equal(de.tool, "fs_read_file");
  assert.equal(dev.content[0]?.type, "text");
  assert.ok((dev.content[0] as { text: string }).text.startsWith("Error ["));

  const un = errorResult(new TransportError("connect_refused", "cannot reach", "ECONNREFUSED"), "net_list_requests");
  const ue = (un.structuredContent as { error: Record<string, unknown> }).error;
  assert.equal(ue.kind, "unreachable");
  assert.equal(ue.status, undefined);
  assert.equal(ue.code, "ECONNREFUSED");

  const ie = (errorResult(new Error("bad arg"), "db_query").structuredContent as { error: Record<string, unknown> }).error;
  assert.equal(ie.kind, "input");
  assert.equal(ie.status, undefined);
});

test("buildCallback routes every error kind through errorResult; success is unaffected", async () => {
  const device = {} as DeviceClient;
  const descriptor = {
    name: "t",
    title: "",
    description: "",
    readOnlyHint: true,
    destructiveHint: false,
    backingMethod: "GET",
    backingPathSuffix: "x",
  };
  const mk = (invoke: () => Promise<unknown>) =>
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    buildCallback(device, descriptor as never, { shape: {}, invoke } as never);

  const errKind = async (invoke: () => Promise<unknown>) => {
    const r = await mk(invoke)({});
    return (r.structuredContent as { error: { kind: string } }).error.kind;
  };

  assert.equal(await errKind(async () => Promise.reject(new DeviceApiError(404, { code: "x", message: "m" }))), "device");
  assert.equal(await errKind(async () => Promise.reject(new TransportError("timeout", "t", "ETIMEDOUT"))), "unreachable");
  assert.equal(await errKind(async () => Promise.reject(new Error("bad"))), "input");

  const ok = await mk(async () => ({ hello: "world" }))({});
  assert.notEqual(ok.isError, true);
  assert.deepEqual(ok.structuredContent, { hello: "world" });
});
