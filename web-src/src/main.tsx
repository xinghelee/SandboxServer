import { render } from 'preact';
import type { ComponentChildren } from 'preact';
import { useEffect, useMemo, useState } from 'preact/hooks';
import { bootstrapToken } from './api/auth';
import { api, ApiRequestError } from './api/client';
import { socket } from './api/ws';
import type { WsStatus } from './api/ws';
import type { Health, Plugin } from './api/types';
import { useRoute, navigate, currentRoute } from './router';
import { useI18n } from './i18n';
import { useTheme } from './theme';
import { Loading } from './components/Spinner';
import { EmptyState } from './components/EmptyState';
import { NetworkPanel } from './panels/network';
import { FilesPanel } from './panels/files';
import { DbPanel } from './panels/db';
import { LogsPanel } from './panels/logs';
import { ScreenPanel } from './panels/screen';
import './styles.css';

// Consume any bootstrap ?token= before anything reads sessionStorage.
bootstrapToken();

// Built-in panels selected by panelKey (panels are not downloaded dynamically).
function panelFor(plugin: Plugin) {
  switch (plugin.panelKey || plugin.id) {
    case 'net':
    case 'network':
      return <NetworkPanel />;
    case 'fs':
    case 'files':
      return <FilesPanel />;
    case 'db':
    case 'database':
      return <DbPanel />;
    case 'logs':
    case 'log':
      return <LogsPanel />;
    case 'screen':
    case 'ui':
      return <ScreenPanel />;
    default:
      return <EmptyState icon="?" title={plugin.panelKey} subKey="err.unknownpanel" />;
  }
}

function WsPill() {
  const { t } = useI18n();
  const [status, setStatus] = useState<WsStatus>(socket.getStatus());
  useEffect(() => socket.onStatus(setStatus), []);
  const label = status === 'open' ? t('ws.live') : status === 'connecting' ? t('ws.connecting') : t('ws.offline');
  return (
    <span class={`ws-pill ${status}`} title={`WebSocket: ${status}`}>
      <span class="led" />
      {label}
    </span>
  );
}

function Controls() {
  const { t, lang, setLang } = useI18n();
  const { theme, setTheme } = useTheme();
  return (
    <div class="controls">
      <div class="seg-toggle" title={t('hdr.lang')}>
        <button class={lang === 'en' ? 'on' : ''} onClick={() => setLang('en')}>
          EN
        </button>
        <button class={lang === 'zh' ? 'on' : ''} onClick={() => setLang('zh')}>
          中文
        </button>
      </div>
      <div class="seg-toggle" title={t('hdr.theme')}>
        <button class={theme === 'light' ? 'on' : ''} onClick={() => setTheme('light')} aria-label="Light">
          ☀
        </button>
        <button class={theme === 'dark' ? 'on' : ''} onClick={() => setTheme('dark')} aria-label="Dark">
          ☾
        </button>
      </div>
    </div>
  );
}

function Header({ health }: { health: Health | null }) {
  const { t } = useI18n();
  const debug = health?.buildConfig === 'debug';
  return (
    <header class="header">
      <div class="brand">
        <span class="logo">SBX</span>
        <span class="sub">{t('brand.sub')}</span>
        {health ? (
          <span class="device">
            {t('hdr.device')}: <b>{health.deviceName}</b>
          </span>
        ) : null}
      </div>
      <div class="spacer" />
      <div class="badges">
        {health ? (
          <>
            <span class={`chip ${debug ? 'ok' : 'warn'}`}>
              <span class="k">{t('hdr.build')}</span>
              <span class="v">{health.buildConfig}</span>
            </span>
            <span class="chip">
              <span class="k">{t('hdr.binding')}</span>
              <span class="v">{health.bindingPolicy}</span>
            </span>
          </>
        ) : null}
        <WsPill />
      </div>
      <Controls />
    </header>
  );
}

function Nav({ plugins, route }: { plugins: Plugin[]; route: string }) {
  const { t } = useI18n();
  const firstKey = plugins[0]?.panelKey || plugins[0]?.id;
  return (
    <nav class="nav">
      <div class="nav-label">{t('nav.modules')}</div>
      {plugins.map((p) => {
        const key = p.panelKey || p.id;
        const target = `/${key}`;
        const active = route === target || (route === '/' && firstKey === key);
        return (
          <a key={key} class={`nav-item ${active ? 'active' : ''}`} onClick={() => navigate(target)}>
            <span class="gutter">{active ? '▸' : '·'}</span>
            <span class="title">{p.title}</span>
            <span class="id">{p.id}</span>
          </a>
        );
      })}
      <div class="nav-foot">
        <div>
          SBX <span class="v">v0.1.0</span>
        </div>
        <div>{t('nav.foot')}</div>
      </div>
    </nav>
  );
}

function Shell({ health, children }: { health: Health | null; children: ComponentChildren }) {
  return (
    <div class="app" style="grid-template-columns:1fr; grid-template-areas:'header' 'main'">
      <Header health={health} />
      <main class="main">{children}</main>
    </div>
  );
}

function App() {
  const route = useRoute();
  const { t } = useI18n();
  const [health, setHealth] = useState<Health | null>(null);
  const [plugins, setPlugins] = useState<Plugin[] | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const [unauthorized, setUnauthorized] = useState(false);

  useEffect(() => {
    const ctrl = new AbortController();
    Promise.all([api.health(ctrl.signal), api.plugins(ctrl.signal)])
      .then(([h, pl]) => {
        if (ctrl.signal.aborted) return;
        setHealth(h);
        setPlugins(pl.items);
        if (currentRoute() === '/' && pl.items.length > 0) {
          navigate(`/${pl.items[0].panelKey || pl.items[0].id}`);
        }
        socket.connect();
      })
      .catch((e: unknown) => {
        if (ctrl.signal.aborted) return;
        if (e instanceof ApiRequestError && e.isUnauthorized) setUnauthorized(true);
        else if (e instanceof ApiRequestError) setFatal(e.message);
        else setFatal(String(e));
      });
    return () => ctrl.abort();
  }, []);

  const activePlugin = useMemo(() => {
    if (!plugins) return null;
    const key = route.replace(/^\//, '');
    return plugins.find((p) => (p.panelKey || p.id) === key) ?? plugins[0] ?? null;
  }, [plugins, route]);

  if (unauthorized) {
    return (
      <Shell health={null}>
        <EmptyState icon="⌬" titleKey="err.unauth.title" subKey="err.unauth.sub" />
      </Shell>
    );
  }

  if (fatal) {
    return (
      <Shell health={null}>
        <div class="error-banner">{fatal}</div>
        <EmptyState icon="⚠" titleKey="err.fatal.title">
          {fatal}
        </EmptyState>
      </Shell>
    );
  }

  if (!plugins) {
    return (
      <div class="app">
        <Header health={health} />
        <nav class="nav" />
        <main class="main">
          <Loading labelKey="err.connecting" />
        </main>
      </div>
    );
  }

  const debugWarn = health && health.buildConfig !== 'debug';

  return (
    <div class="app">
      <Header health={health} />
      <Nav plugins={plugins} route={route} />
      <main class="main">
        {debugWarn ? <div class="warn-banner">{t('warn.nondebug', { build: health!.buildConfig })}</div> : null}
        {activePlugin ? panelFor(activePlugin) : <EmptyState icon="○" titleKey="err.noplugins" />}
      </main>
    </div>
  );
}

const root = document.getElementById('app');
if (root) render(<App />, root);
