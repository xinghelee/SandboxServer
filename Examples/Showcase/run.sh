#!/usr/bin/env bash
# Build, install, and launch the demo on a booted iOS Simulator, then open the debug
# console URL printed by the app. The demo binds localNetwork, so the URL uses a LAN IP.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "Install xcodegen first:  brew install xcodegen"; exit 1; }

echo "▸ Generating project…"
xcodegen generate >/dev/null

SIM_ID=$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()' | head -1 || true)
if [ -z "${SIM_ID:-}" ]; then
  SIM_ID=$(xcrun simctl list devices available | grep -m1 "iPhone" | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()' | head -1)
  echo "▸ Booting simulator $SIM_ID…"
  xcrun simctl boot "$SIM_ID"
fi
open -a Simulator || true

echo "▸ Building for the simulator…"
xcodebuild -project SandboxShowcaseDemo.xcodeproj -scheme SandboxShowcaseDemo \
  -destination "id=$SIM_ID,arch=arm64" -derivedDataPath .build -quiet build

APP=$(find .build/Build/Products -name SandboxShowcaseDemo.app | head -1)
echo "▸ Installing…"
xcrun simctl install "$SIM_ID" "$APP"

LOG=$(mktemp)
echo "▸ Launching…"
xcrun simctl launch --console-pty "$SIM_ID" com.sandboxserver.showcase >"$LOG" 2>&1 &
LP=$!

for _ in $(seq 1 25); do grep -q "console:" "$LOG" 2>/dev/null && break; sleep 1; done
URL=$(grep -oE 'http://[0-9.]+:[0-9]+/(\?token=[A-Z0-9]+)?' "$LOG" | tail -1 || true)

echo
if [ -n "${URL:-}" ]; then
  echo "✅ Console: $URL"
  open "$URL"
else
  echo "⚠️  Could not find the console URL. App log: $LOG"
fi
echo "App is running on the simulator. Press Ctrl-C to stop streaming its logs."
wait "$LP"
