// SandboxServer Console — desktop shell (Electron).
//
// A site-specific browser: the window loads the device's OWN served console URL directly, so
// everything is same-origin to the device and works exactly as it does in a browser tab — no
// CORS, no transport changes to web-src. A small connect page (connect.html) collects the device
// host/port/token (remembered in localStorage) and navigates the window to it.

const { app, BrowserWindow, Menu, shell, ipcMain } = require("electron");
const path = require("path");

// bonjour-service exposes the class as a named/default export depending on interop.
const BonjourMod = require("bonjour-service");
const Bonjour = BonjourMod.Bonjour || BonjourMod.default || BonjourMod;

let win;

/** Browse `_sandboxserver._tcp` for `ms`, returning the de-duplicated peers found. */
function browsePeers(ms = 1500) {
  return new Promise((resolve) => {
    let bonjour;
    try {
      bonjour = new Bonjour();
    } catch {
      resolve([]);
      return;
    }
    const peers = new Map();
    const browser = bonjour.find({ type: "sandboxserver" }, (svc) => {
      const addrs = svc.addresses || [];
      const ipv4 = addrs.find((a) => /^\d+\.\d+\.\d+\.\d+$/.test(a));
      const host = ipv4 || svc.host || addrs[0] || "";
      if (!host || !svc.port) return;
      const txt = svc.txt || {};
      const ra = txt.requiresAuth;
      peers.set(`${host}:${svc.port}:${svc.name}`, {
        name: svc.name,
        host,
        port: svc.port,
        deviceName: txt.deviceName ? String(txt.deviceName) : undefined,
        appBundleId: txt.appBundleId ? String(txt.appBundleId) : undefined,
        requiresAuth: ra === "true" || ra === "1" || ra === "" || ra === true,
        token: txt.token ? String(txt.token) : undefined,
      });
    });
    setTimeout(() => {
      try { browser.stop(); } catch {}
      try { bonjour.destroy(); } catch {}
      resolve([...peers.values()]);
    }, Math.max(300, Math.min(8000, ms)));
  });
}

ipcMain.handle("sbx:discover", (_e, ms) => browsePeers(typeof ms === "number" ? ms : 1500));

function connectPage() {
  win.loadFile(path.join(__dirname, "connect.html"));
}

function createWindow() {
  win = new BrowserWindow({
    width: 1220,
    height: 840,
    minWidth: 760,
    minHeight: 520,
    title: "SandboxServer Console",
    backgroundColor: "#0d1117",
    webPreferences: {
      // Defaults are safe (contextIsolation on, nodeIntegration off). The preload exposes only a
      // narrow `window.sbx.discover()` to the connect page; the device console loads as a normal
      // remote origin (the preload's bridge isn't relevant there).
      preload: path.join(__dirname, "preload.js"),
      spellcheck: false,
    },
  });

  connectPage();
  buildMenu();

  // Keep external links (anything off the device origin, e.g. docs) in the system browser.
  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });
}

function buildMenu() {
  const template = [
    {
      label: app.name,
      submenu: [{ role: "about" }, { type: "separator" }, { role: "hide" }, { role: "quit" }],
    },
    {
      label: "Device",
      submenu: [
        { label: "Connect to a Device…", accelerator: "CmdOrCtrl+O", click: () => connectPage() },
        { label: "Reload", accelerator: "CmdOrCtrl+R", click: () => win && win.reload() },
        { type: "separator" },
        { label: "Back to Console", accelerator: "CmdOrCtrl+]", click: () => win && win.webContents.goForward() },
      ],
    },
    { role: "editMenu" },
    { role: "viewMenu" },
    { role: "windowMenu" },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
