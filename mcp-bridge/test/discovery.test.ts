import { test } from "node:test";
import assert from "node:assert/strict";
import { parseFlags, resolveEndpoint, formatPeers } from "../src/discovery.js";

test("parseFlags handles both --key value and --key=value forms", () => {
  assert.deepEqual(parseFlags(["--host", "h", "--port", "8080", "--token", "T"]), { host: "h", port: 8080, token: "T" });
  assert.deepEqual(parseFlags(["--host=h2", "--port=9", "--no-reconnect"]), { host: "h2", port: 9, reconnect: false });
  assert.deepEqual(parseFlags(["--reconnect", "--timeout=2000"]), { reconnect: true, timeout: 2000 });
  assert.deepEqual(parseFlags([]), {});
});

test("resolveEndpoint returns an explicit endpoint when host+port+token are given", async () => {
  const saved = { ...process.env };
  delete process.env.SANDBOX_HOST;
  delete process.env.SANDBOX_PORT;
  delete process.env.SANDBOX_TOKEN;
  try {
    const r = await resolveEndpoint({ host: "1.2.3.4", port: 8080, token: "tok" });
    assert.equal(r.source, "explicit");
    assert.deepEqual(r.endpoint, { host: "1.2.3.4", port: 8080, token: "tok" });
  } finally {
    process.env = saved;
  }
});

test("resolveEndpoint returns an explicit host+port with no token", async () => {
  const saved = { ...process.env };
  delete process.env.SANDBOX_HOST;
  delete process.env.SANDBOX_PORT;
  delete process.env.SANDBOX_TOKEN;
  try {
    const r = await resolveEndpoint({ host: "1.2.3.4", port: 8080 });
    assert.equal(r.source, "explicit");
    assert.deepEqual(r.endpoint, { host: "1.2.3.4", port: 8080, token: undefined });
  } finally {
    process.env = saved;
  }
});

test("formatPeers summarizes peers, or reports none", () => {
  assert.match(formatPeers([]), /no SandboxServer peers/i);
  const s = formatPeers([{ name: "n", host: "10.0.0.2", port: 8081, addresses: [], txt: { deviceName: "Phone" } }]);
  assert.match(s, /10\.0\.0\.2:8081/);
  assert.match(s, /Phone/);
});
