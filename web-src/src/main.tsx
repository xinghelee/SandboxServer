import { render } from 'preact';
import type { ComponentChildren } from 'preact';
import { useEffect, useMemo, useState } from 'preact/hooks';
import { bootstrapToken, setToken, extractToken, getToken, clearToken } from './api/auth';
import { api, ApiRequestError } from './api/client';
import { socket } from './api/ws';
import type { WsStatus } from './api/ws';
import type { Health, Plugin } from './api/types';
import { useRoute, navigate } from './router';
import { useI18n, moduleName } from './i18n';
import { useTheme } from './theme';
import { CopyButton } from './components/CopyButton';
import { Loading } from './components/Spinner';
import { EmptyState } from './components/EmptyState';
import { OverviewPanel } from './panels/overview';
import { NetworkPanel } from './panels/network';
import { FilesPanel } from './panels/files';
import { DbPanel } from './panels/db';
import { LogsPanel } from './panels/logs';
import { ScreenPanel } from './panels/screen';
import { HierarchyPanel } from './panels/hierarchy';
import { WSPanel } from './panels/ws';
import { BundlePanel } from './panels/bundle';
import { PerfPanel } from './panels/perf';
import './styles.css';

// Consume any bootstrap ?token= before anything reads sessionStorage.
bootstrapToken();

// Built-in panels selected by panelKey (panels are not downloaded dynamically).
function panelFor(plugin: Plugin) {
  switch (plugin.panelKey || plugin.id) {
    case 'net':
    case 'network':
      return <NetworkPanel plugin={plugin} />;
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
    case 'hierarchy':
    case 'layers':
      return <HierarchyPanel />;
    case 'ws':
    case 'websocket':
      return <WSPanel />;
    case 'bundle':
      return <BundlePanel />;
    case 'perf':
    case 'performance':
      return <PerfPanel />;
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
        <button class={lang === 'en' ? 'on' : ''} aria-pressed={lang === 'en'} onClick={() => setLang('en')}>
          EN
        </button>
        <button class={lang === 'zh' ? 'on' : ''} aria-pressed={lang === 'zh'} onClick={() => setLang('zh')}>
          中文
        </button>
      </div>
      <div class="seg-toggle" title={t('hdr.theme')}>
        <button
          class={theme === 'light' ? 'on' : ''}
          aria-pressed={theme === 'light'}
          onClick={() => setTheme('light')}
          aria-label="Light"
        >
          ☀
        </button>
        <button
          class={theme === 'dark' ? 'on' : ''}
          aria-pressed={theme === 'dark'}
          onClick={() => setTheme('dark')}
          aria-label="Dark"
        >
          ☾
        </button>
      </div>
    </div>
  );
}

function Header({ health }: { health: Health | null }) {
  const { t } = useI18n();
  const debug = health?.buildConfig === 'debug';
  const endpoint = typeof window !== 'undefined' ? window.location.host : health?.bindingPolicy;
  return (
    <header class="header">
      <div class="brand">
        <span class="logo" aria-hidden="true">
          <svg class="logo-icon" viewBox="0 0 24 24" focusable="false">
            <path d="M6.2 7.4 2.8 12l3.4 4.6" />
            <path d="M17.8 7.4 21.2 12l-3.4 4.6" />
            <path d="M9.2 17.2 14.8 6.8" />
            <circle cx="12" cy="12" r="2.3" />
          </svg>
        </span>
        <span class="brand-copy">
          <span class="sub">{t('brand.sub')}</span>
          {health ? (
            <span class="device">
              {t('hdr.device')}: <b>{health.deviceName}</b>
            </span>
          ) : null}
        </span>
      </div>
      <div class="spacer" />
      <div class="badges">
        {health ? (
          <>
            <span class={`chip ${debug ? 'ok' : 'warn'}`}>
              <span class="k">{t('hdr.build')}</span>
              <span class="v">{health.buildConfig}</span>
            </span>
            <span class="chip" title={`${health.bindingPolicy} · ${endpoint}`}>
              <span class="k">{t('hdr.binding')}</span>
              <span class="v">{endpoint}</span>
            </span>
          </>
        ) : null}
        <WsPill />
      </div>
      <Controls />
    </header>
  );
}

type NavVisual = {
  icon: string;
  accent: string;
};

const DEFAULT_NAV_VISUAL: NavVisual = { icon: '·', accent: 'var(--ink-dim)' };

const NAV_VISUALS: Record<string, NavVisual> = {
  home: { icon: '⌂', accent: 'var(--accent)' },
  net: { icon: '↗', accent: 'var(--s3)' },
  network: { icon: '↗', accent: 'var(--s3)' },
  fs: { icon: '▣', accent: 'var(--accent)' },
  files: { icon: '▣', accent: 'var(--accent)' },
  db: { icon: '◫', accent: '#a371f7' },
  database: { icon: '◫', accent: '#a371f7' },
  logs: { icon: '≡', accent: 'var(--s4)' },
  log: { icon: '≡', accent: 'var(--s4)' },
  screen: { icon: '▯', accent: '#39c5bb' },
  hierarchy: { icon: '▱', accent: '#f778ba' },
  layers: { icon: '▱', accent: '#f778ba' },
  ws: { icon: '⇄', accent: 'var(--link)' },
  websocket: { icon: '⇄', accent: 'var(--link)' },
  bundle: { icon: '⬡', accent: '#d29922' },
  perf: { icon: '◴', accent: '#3fb950' },
  performance: { icon: '◴', accent: '#3fb950' },
  mcp: { icon: '⌘', accent: '#39c5bb' },
};

function navVisual(id: string, key?: string): NavVisual {
  return NAV_VISUALS[key || ''] ?? NAV_VISUALS[id] ?? DEFAULT_NAV_VISUAL;
}

function moduleSubtitle(id: string): string {
  return id === 'bundle' ? 'playload' : id;
}

function NavLink({
  target,
  active,
  title,
  code,
  visual,
}: {
  target: string;
  active: boolean;
  title: string;
  code: string;
  visual: NavVisual;
}) {
  return (
    <a
      href={`#${target}`}
      class={`nav-item ${active ? 'active' : ''}`}
      aria-current={active ? 'page' : undefined}
      style={`--item-accent:${visual.accent}`}
      onClick={(e) => {
        e.preventDefault();
        navigate(target);
      }}
    >
      <span class="nav-icon" aria-hidden="true">
        {visual.icon}
      </span>
      <span class="nav-text">
        <span class="title">{title}</span>
        <span class="id">{code}</span>
      </span>
    </a>
  );
}

function Nav({ plugins, route }: { plugins: Plugin[]; route: string }) {
  const { t } = useI18n();
  const overviewActive = route === '/' || route === '/overview';
  return (
    <nav class="nav">
      <div class="nav-section nav-section-primary">
        <NavLink
          target="/overview"
          active={overviewActive}
          title={t('home.title')}
          code="home"
          visual={navVisual('home')}
        />
      </div>
      <div class="nav-section">
        <div class="nav-label">{t('nav.modules')}</div>
        {plugins.map((p) => {
          const key = p.panelKey || p.id;
          const target = `/${key}`;
          return (
            <NavLink
              key={key}
              target={target}
              active={route === target}
              title={moduleName(p.id, p.title)}
              code={moduleSubtitle(p.id)}
              visual={navVisual(p.id, key)}
            />
          );
        })}
      </div>
      <div class="nav-section">
        <NavLink
          target="/mcp"
          active={route === '/mcp'}
          title={t('mcp.title')}
          code="mcp"
          visual={navVisual('mcp')}
        />
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

/** Recover from a missing/stale token without a full page reload: paste a token (or the
 *  whole console URL) and reconnect in place. */
function ConnectForm({ onConnect }: { onConnect: () => void }) {
  const { t } = useI18n();
  const [val, setVal] = useState('');
  const submit = (e: Event) => {
    e.preventDefault();
    const tok = extractToken(val);
    if (tok) setToken(tok);
    onConnect();
  };
  return (
    <form class="connect-form" onSubmit={submit}>
      <input
        class="input"
        type="text"
        autocomplete="off"
        spellcheck={false}
        placeholder={t('err.token.placeholder')}
        value={val}
        onInput={(e) => setVal((e.currentTarget as HTMLInputElement).value)}
      />
      <button class="btn primary" type="submit">
        {t('err.token.apply')}
      </button>
    </form>
  );
}

function McpPanel({ health, plugins }: { health: Health | null; plugins: Plugin[] }) {
  const { t } = useI18n();
  const token = getToken();
  const host = window.location.hostname;
  const port = window.location.port || (window.location.protocol === 'https:' ? '443' : '80');
  const tools = plugins.flatMap((p) => (p.mcpTools ?? []).map((tool) => ({ plugin: p, tool })));
  const env = {
    SANDBOX_HOST: host,
    SANDBOX_PORT: port,
    ...(token ? { SANDBOX_TOKEN: token } : {}),
  };
  const doctorCommand =
    `SANDBOX_HOST=${host} SANDBOX_PORT=${port}` +
    (token ? ` SANDBOX_TOKEN=${token}` : '') +
    ' npx -y sandbox-mcp doctor';
  const config = JSON.stringify(
    {
      mcpServers: {
        sandbox: {
          command: 'npx',
          args: ['-y', 'sandbox-mcp'],
          env,
        },
      },
    },
    null,
    2,
  );

  return (
    <div class="panel mcp-panel">
      <div class="panel-toolbar">
        <h2>{t('mcp.title')}</h2>
        <span class="count-chip">{t('mcp.tools', { n: tools.length + 1 })}</span>
      </div>

      <section class="mcp-hero">
        <div>
          <div class="mcp-eyebrow">{t('mcp.bridge')}</div>
          <h3>{t('mcp.hero')}</h3>
          <p>{t('mcp.sub')}</p>
        </div>
        <div class="mcp-endpoint" aria-label={t('mcp.endpoint')}>
          <span>{t('mcp.endpoint')}</span>
          <strong>{host}:{port}</strong>
          <em>{health?.requiresAuth ?? true ? t('mcp.auth.token') : t('mcp.auth.open')}</em>
        </div>
      </section>

      <div class="mcp-grid">
        <section class="mcp-card">
          <div class="mcp-card-head">
            <h3>{t('mcp.step1')}</h3>
            <CopyButton text={doctorCommand} />
          </div>
          <p>{t('mcp.step1.sub')}</p>
          <pre class="mcp-code">{doctorCommand}</pre>
        </section>

        <section class="mcp-card wide">
          <div class="mcp-card-head">
            <h3>{t('mcp.step2')}</h3>
            <CopyButton text={config} />
          </div>
          <p>{t('mcp.step2.sub')}</p>
          <pre class="mcp-code">{config}</pre>
        </section>

        <section class="mcp-card wide">
          <div class="mcp-card-head">
            <h3>{t('mcp.step3')}</h3>
          </div>
          <p>{t('mcp.step3.sub')}</p>
          <div class="mcp-tool-list">
            <div class="mcp-tool">
              <span class="mcp-tool-name">sandbox_status</span>
              <span class="mcp-tool-meta">{t('mcp.statusTool')}</span>
            </div>
            {tools.map(({ plugin, tool }) => (
              <div class="mcp-tool" key={`${plugin.id}:${tool.name}`}>
                <span class="mcp-tool-name">{tool.name}</span>
                <span class="mcp-tool-meta">{moduleName(plugin.id, plugin.title)} · {tool.readOnlyHint ? t('mcp.readonly') : t('mcp.write')}</span>
              </div>
            ))}
          </div>
        </section>
      </div>
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
  const [nonce, setNonce] = useState(0);
  const isMcp = route === '/mcp';
  const reconnect = () => setNonce((n) => n + 1);

  useEffect(() => {
    const ctrl = new AbortController();
    setFatal(null);
    setUnauthorized(false);
    // Fetch health and plugins independently (not Promise.all): one failing shouldn't blank
    // the other, and `plugins` is the call whose 401 gates the console. Both sit under
    // /__sandbox/api (token-gated when auth==.token; with the default .none they just succeed).
    api
      .health(ctrl.signal)
      .then((h) => {
        if (!ctrl.signal.aborted) setHealth(h);
      })
      .catch(() => {
        /* connectivity is reported by the plugins() call below */
      });
    api
      .plugins(ctrl.signal)
      .then((pl) => {
        if (ctrl.signal.aborted) return;
        setPlugins(pl.items);
        // Root route ('/') lands on the Overview dashboard — no redirect to the first plugin.
        socket.connect();
      })
      .catch((e: unknown) => {
        if (ctrl.signal.aborted) return;
        if (e instanceof ApiRequestError && e.isUnauthorized) {
          if (isMcp) {
            clearToken();
            setPlugins([]);
          }
          else setUnauthorized(true);
        }
        else if (e instanceof ApiRequestError) setFatal(e.message);
        else setFatal(String(e));
      });
    return () => ctrl.abort();
  }, [nonce, isMcp]);

  const activePlugin = useMemo(() => {
    if (!plugins) return null;
    const key = route.replace(/^\//, '');
    return plugins.find((p) => (p.panelKey || p.id) === key) ?? plugins[0] ?? null;
  }, [plugins, route]);

  if (isMcp && (unauthorized || fatal || !plugins)) {
    return (
      <div class="app">
        <Header health={health} />
        <Nav plugins={plugins ?? []} route={route} />
        <main class="main">
          <McpPanel health={health} plugins={plugins ?? []} />
        </main>
      </div>
    );
  }

  if (unauthorized) {
    return (
      <Shell health={health}>
        <div class="recover">
          <EmptyState icon="⌬" titleKey="err.unauth.title" subKey="err.unauth.sub" />
          <ConnectForm onConnect={reconnect} />
        </div>
      </Shell>
    );
  }

  if (fatal) {
    return (
      <Shell health={health}>
        <div class="recover">
          <EmptyState icon="⚠" titleKey="err.fatal.title">
            {fatal}
          </EmptyState>
          <button class="btn" onClick={reconnect}>
            {t('err.retry')}
          </button>
        </div>
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
  const isOverview = route === '/' || route === '/overview';

  return (
    <div class="app">
      <Header health={health} />
      <Nav plugins={plugins} route={route} />
      <main class="main">
        {debugWarn ? <div class="warn-banner">{t('warn.nondebug', { build: health!.buildConfig })}</div> : null}
        {isOverview ? (
          <OverviewPanel health={health} plugins={plugins} />
        ) : isMcp ? (
          <McpPanel health={health} plugins={plugins} />
        ) : activePlugin ? (
          panelFor(activePlugin)
        ) : (
          <EmptyState icon="○" titleKey="err.noplugins" />
        )}
      </main>
    </div>
  );
}

const root = document.getElementById('app');
if (root) render(<App />, root);
