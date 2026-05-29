#!/usr/bin/env node
/**
 * sandbox-mcp — MCP bridge for SandboxServer (iOS debug SDK).
 *
 * Subcommands:
 *   sandbox-mcp                connect (default): discover -> healthz -> register -> stdio
 *   sandbox-mcp discover       browse the LAN, print peers, exit
 *   sandbox-mcp doctor         probe /healthz, warn if buildConfig !== debug, exit
 *
 * Transport is StdioServerTransport ONLY. All diagnostics go to stderr; stdout
 * is reserved exclusively for the JSON-RPC stream the SDK manages.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { DeviceClient, HEALTHZ_TIMEOUT_MS } from "./deviceClient.js";
import { browse, formatPeers, parseFlags, resolveEndpoint, type CliFlags } from "./discovery.js";
import { registerAll } from "./registerTools.js";
import { createSupervisor, isReconnectEnabled, type Supervisor } from "./reconnect.js";
import { log } from "./log.js";

const PKG_NAME = "sandbox-mcp";
const PKG_VERSION = "0.1.0";

function printUsage(): void {
  log.banner(
    [
      `${PKG_NAME} v${PKG_VERSION} — MCP bridge for SandboxServer`,
      "",
      "Usage:",
      "  sandbox-mcp [--host H --port P --token T]   connect over stdio (default)",
      "  sandbox-mcp discover [--timeout ms]         list LAN devices and exit",
      "  sandbox-mcp doctor   [--host ...]           probe /healthz and exit",
      "",
      "Env: SANDBOX_HOST, SANDBOX_PORT, SANDBOX_TOKEN, SANDBOX_MCP_LOG=debug|info|warn|error",
    ].join("\n"),
  );
}

async function cmdDiscover(flags: CliFlags): Promise<number> {
  const peers = await browse(flags.timeout);
  log.banner(`Found ${peers.length} SandboxServer peer(s):`);
  log.banner(formatPeers(peers));
  return 0;
}

async function cmdDoctor(flags: CliFlags): Promise<number> {
  const { endpoint, source, peer } = await resolveEndpoint(flags);
  log.banner(
    `Resolved endpoint via ${source}: ${endpoint.host}:${endpoint.port}` +
      (peer?.txt.deviceName ? ` ("${peer.txt.deviceName}")` : ""),
  );
  const device = new DeviceClient(endpoint);
  const health = await device.healthz({ timeoutMs: HEALTHZ_TIMEOUT_MS });
  log.banner("healthz:");
  log.banner(JSON.stringify(health, null, 2));
  if (health.buildConfig !== "debug") {
    log.banner(
      `WARNING: buildConfig is "${health.buildConfig}", not "debug". ` +
        "SandboxServer is intended for debug builds only — this may be a misconfiguration.",
    );
    return 2;
  }
  log.banner("OK: device is healthy and running a debug build.");
  return 0;
}

async function cmdConnect(flags: CliFlags): Promise<number> {
  const { endpoint, source, peer } = await resolveEndpoint(flags);
  const device = new DeviceClient(endpoint);

  // Health check before registering — fail fast with a clear stderr message.
  const health = await device.healthz({ timeoutMs: HEALTHZ_TIMEOUT_MS });
  if (health.buildConfig !== "debug") {
    log.warn(`buildConfig is "${health.buildConfig}", not "debug" — proceeding anyway.`);
  }

  const server = new McpServer({ name: PKG_NAME, version: PKG_VERSION });
  const { toolCount, pluginCount } = await registerAll(server, device);

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Keep the long-lived session alive across device restarts/rebinds (default on;
  // disable with --no-reconnect or SANDBOX_RECONNECT=0). Tools registered above keep
  // working because the supervisor swaps the endpoint into `device` in place.
  let supervisor: Supervisor | undefined;
  if (isReconnectEnabled(flags)) {
    supervisor = createSupervisor({ device, flags });
    supervisor.start();
    log.debug("reconnect supervisor started");
  }

  // One-time startup banner (stderr).
  const deviceLabel = health.deviceName || peer?.txt.deviceName || `${endpoint.host}:${endpoint.port}`;
  log.banner(
    `${PKG_NAME} v${PKG_VERSION} connected (${source}) -> ${deviceLabel} ` +
      `[${endpoint.host}:${endpoint.port}] app=${health.appBundleId} build=${health.buildConfig} ` +
      `| ${pluginCount} plugin(s), ${toolCount} tool(s) registered` +
      `${supervisor ? " | auto-reconnect on" : ""}`,
  );

  const shutdown = async (signal: string) => {
    log.info(`received ${signal}, shutting down...`);
    supervisor?.stop();
    try {
      await server.close();
    } catch (err) {
      log.warn(`error during shutdown: ${err instanceof Error ? err.message : String(err)}`);
    }
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));

  // Keep the process alive; the transport drives I/O over stdio.
  return new Promise<number>(() => {
    /* never resolves until a signal triggers process.exit */
  });
}

async function main(): Promise<void> {
  const [, , maybeCmd, ...rest] = process.argv;

  let command = "connect";
  let argv = process.argv.slice(2);
  if (maybeCmd && !maybeCmd.startsWith("-")) {
    command = maybeCmd;
    argv = rest;
  }

  const flags = parseFlags(argv);

  let code = 0;
  switch (command) {
    case "discover":
      code = await cmdDiscover(flags);
      process.exit(code);
      break;
    case "doctor":
      code = await cmdDoctor(flags);
      process.exit(code);
      break;
    case "help":
    case "--help":
    case "-h":
      printUsage();
      process.exit(0);
      break;
    case "connect":
      await cmdConnect(flags);
      break;
    default:
      log.error(`unknown subcommand: ${command}`);
      printUsage();
      process.exit(1);
  }
}

main().catch((err) => {
  log.error(err instanceof Error ? (err.stack ?? err.message) : String(err));
  process.exit(1);
});
