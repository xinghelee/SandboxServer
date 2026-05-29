/**
 * stderr-only logger.
 *
 * CRITICAL: when the MCP server runs over StdioServerTransport, stdout is the
 * JSON-RPC stream owned by the SDK. ANY stray byte on stdout corrupts the
 * protocol and is the #1 cause of "connects but no tools". Every diagnostic
 * here therefore goes to stderr (process.stderr / console.error), never stdout.
 */

type Level = "debug" | "info" | "warn" | "error";

const LEVELS: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

function envLevel(): number {
  const raw = (process.env.SANDBOX_MCP_LOG ?? "info").toLowerCase();
  return LEVELS[raw as Level] ?? LEVELS.info;
}

const threshold = envLevel();

function emit(level: Level, args: unknown[]): void {
  if (LEVELS[level] < threshold) return;
  const ts = new Date().toISOString();
  const prefix = `[sandbox-mcp ${ts} ${level.toUpperCase()}]`;
  // console.error writes to stderr (fd 2), never stdout.
  console.error(prefix, ...args);
}

export const log = {
  debug: (...args: unknown[]) => emit("debug", args),
  info: (...args: unknown[]) => emit("info", args),
  warn: (...args: unknown[]) => emit("warn", args),
  error: (...args: unknown[]) => emit("error", args),
  /** Write a raw line directly to stderr (used for the startup banner). */
  banner: (line: string) => {
    process.stderr.write(line + "\n");
  },
};
