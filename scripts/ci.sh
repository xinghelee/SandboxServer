#!/usr/bin/env bash
#
# Local CI mirror for SandboxServer.
#
# Runs exactly the checks a GitHub Actions workflow would, so you can validate
# locally — before (or without) a remote repository.
#
#   ./scripts/ci.sh
#
# Jobs:
#   1. Swift — real core (trait on): build + full test suite
#   2. Swift — no-op path (trait off): build + test (the Release-safe facade must stay green)
#   3. Web console — build, then assert the committed Resources/web is in sync (drift check)
#   4. MCP bridge — TypeScript build + unit tests
#
# Dependencies: in CI ($CI is set, e.g. by GitHub Actions) node deps are installed
# with `npm ci`; locally, an existing node_modules is reused for speed (set CI=1 to force).

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FAILED=()

# Colors only when stdout is a TTY (keeps CI logs clean).
if [ -t 1 ]; then
  C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_RED=''; C_OFF=''
fi
step() { printf "\n%s▶ %s%s\n" "$C_CYAN" "$1" "$C_OFF"; }
ok()   { printf "%s✓ %s%s\n" "$C_GREEN" "$1" "$C_OFF"; }
fail() { printf "%s✗ %s%s\n" "$C_RED" "$1" "$C_OFF"; FAILED+=("$1"); }

ensure_deps() {
  local dir="$1"
  if [ -n "${CI:-}" ] || [ ! -d "$dir/node_modules" ]; then
    ( cd "$dir" && npm ci )
  else
    echo "  (node_modules present; reusing — set CI=1 to force a clean npm ci)"
  fi
}

# ── Job 1: Swift, real core (trait on) — build + test ───────────────────────
step "Swift — real core (trait on): build + test"
if swift test --traits SandboxServerEnabled; then
  ok "swift test --traits SandboxServerEnabled"
else
  fail "swift test --traits SandboxServerEnabled"
fi

# ── Job 2: Swift, no-op path (trait off) — build + test ─────────────────────
# `swift test` (not just build) so a broken no-op start(), or a test that fails to compile to empty
# under the disabled trait, can't slip through. The suite is wrapped in #if SandboxServerEnabled,
# so trait-off runs 0 tests but still type-checks the no-op product + facade + the test target.
step "Swift — no-op path (trait off): build + test"
if swift test; then
  ok "swift test (no-op / Release-safe path)"
else
  fail "swift test (no-op / Release-safe path)"
fi

# ── Job 3: Web console — build + committed-artifact drift check ──────────────
step "Web console — build + artifact drift check"
ensure_deps "$ROOT/web-src"
if ( cd "$ROOT/web-src" && npm run build ); then
  DRIFT="$(git status --porcelain -- Sources/SandboxServerCore/Resources/web)"
  if [ -z "$DRIFT" ]; then
    ok "web artifact in sync with committed Resources/web"
  else
    fail "web artifact drift — run 'cd web-src && npm run build' and commit Sources/SandboxServerCore/Resources/web"
    printf "%s\n" "$DRIFT"
  fi
else
  fail "web console build"
fi

# ── Job 4: MCP bridge — TypeScript build + tests ────────────────────────────
step "MCP bridge — TypeScript build + tests"
ensure_deps "$ROOT/mcp-bridge"
if ( cd "$ROOT/mcp-bridge" && npm run build ); then
  ok "mcp-bridge tsc build"
else
  fail "mcp-bridge build"
fi
if ( cd "$ROOT/mcp-bridge" && npm test ); then
  ok "mcp-bridge npm test"
else
  fail "mcp-bridge npm test"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
printf '%.0s─' {1..60}; echo
if [ ${#FAILED[@]} -eq 0 ]; then
  printf "%sCI PASSED — all checks green.%s\n" "$C_GREEN" "$C_OFF"
  exit 0
fi
printf "%sCI FAILED (%d):%s\n" "$C_RED" "${#FAILED[@]}" "$C_OFF"
for f in "${FAILED[@]}"; do echo "  - $f"; done
exit 1
