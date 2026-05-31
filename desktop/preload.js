// Exposes a tiny, safe API to the connect page (contextIsolation stays on). The renderer can ask
// the main process to browse the LAN for SandboxServer devices; it gets back plain peer objects.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("sbx", {
  discover: (ms) => ipcRenderer.invoke("sbx:discover", ms),
});
