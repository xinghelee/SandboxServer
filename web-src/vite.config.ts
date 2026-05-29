import { defineConfig, loadEnv } from 'vite';
import preact from '@preact/preset-vite';

// SandboxServer web console build config.
// - relative base so the SPA is path-agnostic (served from / by the Swift SDK)
// - output a flat index.html + assets/ into the Swift package Resources dir
// - dev proxy forwards /__sandbox to the device (REST + WS)
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const apiBase = env.VITE_API_BASE || 'http://127.0.0.1:8080';

  return {
    base: './',
    plugins: [preact()],
    build: {
      outDir: '../Sources/SandboxServerCore/Resources/web',
      emptyOutDir: true,
      assetsDir: 'assets',
      target: 'es2020',
      sourcemap: false,
    },
    server: {
      proxy: {
        '/__sandbox': {
          target: apiBase,
          changeOrigin: true,
          ws: true,
        },
      },
    },
  };
});
