import { test } from "node:test";
import assert from "node:assert/strict";
import { DeviceClient } from "../src/deviceClient.js";
import { buildReplayBody, fillPath, pickQuery } from "../src/registerTools.js";

const ENDPOINT = { host: "127.0.0.1", port: 8080, token: "t" } as const;

test("buildUrl prefixes the API path and drops empty/undefined query values", () => {
  const c = new DeviceClient(ENDPOINT);
  assert.equal(c.buildUrl("net/requests"), "http://127.0.0.1:8080/__sandbox/api/v1/net/requests");
  assert.equal(
    c.buildUrl("net/requests", { limit: 5, cursor: undefined, host: "", method: "GET" }),
    "http://127.0.0.1:8080/__sandbox/api/v1/net/requests?limit=5&method=GET",
  );
});

test("fillPath substitutes {params}, percent-encodes them, and rejects a missing one", () => {
  const consumed = new Set<string>();
  assert.equal(fillPath("requests/{id}", { id: "42" }, consumed), "requests/42");
  assert.ok(consumed.has("id"), "the substituted key is marked consumed");
  assert.equal(fillPath("db/{dbId}/tables", { dbId: "/a/b c.sqlite" }, new Set()), "db/%2Fa%2Fb%20c.sqlite/tables");
  assert.throws(() => fillPath("requests/{id}", {}, new Set()), /Missing path parameter/);
});

test("pickQuery keeps only present, non-empty keys", () => {
  assert.deepEqual(
    pickQuery({ a: 1, b: "", c: null, d: "x", e: undefined, f: false }, ["a", "b", "c", "d", "e", "f"]),
    { a: 1, d: "x", f: false },
  );
});

test("buildReplayBody base64-encodes a UTF-8 body, passes headers through, and omits absent fields", () => {
  // id-only → faithful replay (empty override body): no headers, no body.
  assert.deepEqual(buildReplayBody({ id: "x" }), {});
  // method/url replace the request line; headers pass straight through; body is base64 of the UTF-8 text.
  assert.deepEqual(buildReplayBody({ id: "x", method: "post", url: " https://example.com/retry ", headers: { "X-Tag": "1" }, body: "héllo" }), {
    method: "POST",
    url: "https://example.com/retry",
    headers: { "X-Tag": "1" },
    body: Buffer.from("héllo", "utf8").toString("base64"),
  });
  // a string[] or non-object headers value is ignored (not forwarded as headers).
  assert.deepEqual(buildReplayBody({ id: "x", headers: ["bad"] }), {});
  // an empty-string body still overrides (sends an empty body), distinct from omitting it.
  assert.deepEqual(buildReplayBody({ id: "x", body: "" }), { body: "" });
});
