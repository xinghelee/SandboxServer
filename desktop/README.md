# SandboxServer Console — desktop app (Electron)

A thin macOS/desktop shell around the SandboxServer debug console. It is a **site-specific
browser**: the window loads the device's own served console URL directly, so everything is
same-origin to the device and behaves exactly like a browser tab — no CORS, and no changes to
the `web-src` console. A small connect page collects the device host/port/token (remembered
across launches) and navigates to it.

## Run (dev)

```bash
cd desktop
npm install
npm start
```

Enter the device's host + port (and a token only if it runs `auth: .token`). The device prints
its console URL on `start()` — e.g. `http://192.168.1.20:8080/`. The simulator demo is reachable
at `127.0.0.1:8080`.

## Package a macOS .app

```bash
cd desktop
npm install
npm run package:mac        # → dist/SandboxServer Console-darwin-arm64/SandboxServer Console.app
```

The produced `.app` is **unsigned** (fine for internal/trusted use — the SDK is a debug tool).
On first launch macOS Gatekeeper may require right-click → Open. For an Intel Mac change
`--arch=arm64` to `--arch=x64` (or `--arch=universal`).

## Notes

- Connection is remembered in `localStorage` (recent devices on the connect screen).
- This wrapper does **not** bundle the console assets — it always shows the device's live console,
  so it stays in sync with whatever SDK version the device runs.
- It does not co-host the `sandbox-mcp` bridge (that's a Node process; run it separately for AI
  clients). Electron was chosen over Tauri so the bridge could later be co-hosted in-process if
  desired.
