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
import { DefaultsPanel } from './panels/defaults';
import { DevicePanel } from './panels/device';
import { DeepLinkPanel } from './panels/deeplink';
import { NotifyPanel } from './panels/notify';
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
    case 'defaults':
      return <DefaultsPanel />;
    case 'device':
      return <DevicePanel />;
    case 'deeplink':
      return <DeepLinkPanel />;
    case 'notify':
      return <NotifyPanel />;
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
  icon: NavIconName;
  accent: string;
};

type NavIconName =
  | 'overview'
  | 'network'
  | 'files'
  | 'database'
  | 'logs'
  | 'screen'
  | 'layers'
  | 'websocket'
  | 'bundle'
  | 'performance'
  | 'defaults'
  | 'device'
  | 'deeplink'
  | 'notify'
  | 'mcp'
  | 'plugin';

const DEFAULT_NAV_VISUAL: NavVisual = { icon: 'plugin', accent: 'var(--ink-dim)' };

const NAV_VISUALS: Record<string, NavVisual> = {
  home: { icon: 'overview', accent: 'var(--accent)' },
  net: { icon: 'network', accent: 'var(--s3)' },
  network: { icon: 'network', accent: 'var(--s3)' },
  fs: { icon: 'files', accent: 'var(--accent)' },
  files: { icon: 'files', accent: 'var(--accent)' },
  db: { icon: 'database', accent: '#a371f7' },
  database: { icon: 'database', accent: '#a371f7' },
  logs: { icon: 'logs', accent: 'var(--s4)' },
  log: { icon: 'logs', accent: 'var(--s4)' },
  screen: { icon: 'screen', accent: '#39c5bb' },
  hierarchy: { icon: 'layers', accent: '#f778ba' },
  layers: { icon: 'layers', accent: '#f778ba' },
  ws: { icon: 'websocket', accent: 'var(--link)' },
  websocket: { icon: 'websocket', accent: 'var(--link)' },
  bundle: { icon: 'bundle', accent: '#d29922' },
  perf: { icon: 'performance', accent: '#3fb950' },
  performance: { icon: 'performance', accent: '#3fb950' },
  defaults: { icon: 'defaults', accent: '#e3b341' },
  device: { icon: 'device', accent: '#58a6ff' },
  deeplink: { icon: 'deeplink', accent: '#a371f7' },
  notify: { icon: 'notify', accent: '#db61a2' },
  mcp: { icon: 'mcp', accent: '#39c5bb' },
};

function navVisual(id: string, key?: string): NavVisual {
  return NAV_VISUALS[key || ''] ?? NAV_VISUALS[id] ?? DEFAULT_NAV_VISUAL;
}

function NavIcon({ name }: { name: NavIconName }) {
  switch (name) {
    case 'overview':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <rect x="5" y="5" width="5.5" height="5.5" rx="1.4" />
          <rect x="13.5" y="5" width="5.5" height="5.5" rx="1.4" />
          <rect x="5" y="13.5" width="5.5" height="5.5" rx="1.4" />
          <rect x="13.5" y="13.5" width="5.5" height="5.5" rx="1.4" />
        </svg>
      );
    case 'network':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <circle class="nav-dot" cx="6" cy="12" r="2" />
          <circle class="nav-dot" cx="13.5" cy="7" r="2" />
          <circle class="nav-dot" cx="18" cy="16" r="2" />
          <path d="M7.8 10.8 11.8 8.2M7.9 13l8.1 2.2M14.6 8.8l2.3 5.4" />
        </svg>
      );
    case 'websocket':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="M6 8.5h8l-2.3-2.3M18 15.5h-8l2.3 2.3" />
          <path d="M5 6v12M19 6v12" />
          <circle class="nav-dot" cx="5" cy="6" r="1.5" />
          <circle class="nav-dot" cx="19" cy="18" r="1.5" />
        </svg>
      );
    case 'logs':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="M7 4.5h7.2L17.5 8v11.5H7z" />
          <path d="M14 4.8V8h3.2" />
          <path d="M9.5 11.5h5M9.5 14.8h5M9.5 18h3.5" />
        </svg>
      );
    case 'performance':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="M4.5 18.5h15" />
          <path d="m5.5 15 3.2-4.2 3 2.8 4.1-6.2 2.7 4.2" />
          <circle class="nav-dot" cx="15.8" cy="7.4" r="1.5" />
        </svg>
      );
    case 'files':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="M4.5 8.2h5l1.7 2h8.3V18a2 2 0 0 1-2 2h-11a2 2 0 0 1-2-2z" />
          <path d="M4.5 8.2V7a2 2 0 0 1 2-2h3.2l1.6 2h5.2a2 2 0 0 1 2 2v1.2" />
        </svg>
      );
    case 'database':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <ellipse cx="12" cy="6.5" rx="6" ry="2.8" />
          <path d="M6 6.5v8.8c0 1.5 2.7 2.7 6 2.7s6-1.2 6-2.7V6.5" />
          <path d="M6 11c0 1.5 2.7 2.7 6 2.7s6-1.2 6-2.7" />
        </svg>
      );
    case 'defaults':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="M5 7h6M15 7h4M5 12h10M19 12h0M5 17h3M12 17h7" />
          <circle cx="13" cy="7" r="2" />
          <circle cx="17" cy="12" r="2" />
          <circle cx="10" cy="17" r="2" />
        </svg>
      );
    case 'screen':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <rect x="7" y="3.5" width="10" height="17" rx="2.5" />
          <path d="M10.5 17.5h3" />
          <circle class="nav-dot" cx="12" cy="6.5" r=".75" />
        </svg>
      );
    case 'layers':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="m12 5 7 3.7-7 3.7-7-3.7z" />
          <path d="m5 12 7 3.7 7-3.7M5 15.8l7 3.7 7-3.7" />
        </svg>
      );
    case 'bundle':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="m12 4.3 6.6 3.8v7.8L12 19.7l-6.6-3.8V8.1z" />
          <path d="m5.7 8.4 6.3 3.5 6.3-3.5M12 12v7.2" />
        </svg>
      );
    case 'device':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <rect x="6" y="4" width="12" height="16" rx="2.5" />
          <path d="M9.5 8h5M9.5 12h5M9.5 16h2.5" />
          <path d="M18 9.5h2M18 14.5h2M4 9.5h2M4 14.5h2" />
        </svg>
      );
    case 'deeplink':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="M9.5 14.5 14.5 9.5" />
          <path d="M10.3 7.8 12 6.1a3.8 3.8 0 0 1 5.4 5.4l-1.7 1.7" />
          <path d="M13.7 16.2 12 17.9a3.8 3.8 0 0 1-5.4-5.4l1.7-1.7" />
        </svg>
      );
    case 'notify':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <path d="M18 15.5V11a6 6 0 0 0-12 0v4.5L4.5 18h15z" />
          <path d="M10 20h4" />
          <circle class="nav-dot" cx="17.5" cy="6.2" r="1.4" />
        </svg>
      );
    case 'mcp':
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <circle class="nav-dot" cx="6.5" cy="7" r="2" />
          <circle class="nav-dot" cx="17.5" cy="7" r="2" />
          <circle class="nav-dot" cx="12" cy="17" r="2" />
          <path d="M8.4 7h7.2M7.4 8.8l3.7 6.5M16.6 8.8l-3.7 6.5" />
        </svg>
      );
    default:
      return (
        <svg class="nav-svg" viewBox="0 0 24 24" focusable="false">
          <rect x="5" y="5" width="14" height="14" rx="3" />
          <path d="M9 9h6v6H9z" />
        </svg>
      );
  }
}

function moduleSubtitle(id: string): string {
  return id === 'bundle' ? 'playload' : id;
}

// Sidebar grouping (ordered). A group renders only if it has present plugins; the nav is
// manifest-driven, so any plugin NOT listed here falls into a trailing "other" group and is
// never dropped. Group titles come from i18n keys `nav.group.<key>`.
const NAV_GROUPS: { key: string; ids: string[] }[] = [
  { key: 'observe', ids: ['net', 'ws', 'logs', 'perf'] },
  { key: 'data', ids: ['fs', 'db', 'defaults'] },
  { key: 'ui', ids: ['screen', 'hierarchy'] },
  { key: 'app', ids: ['bundle', 'device', 'deeplink', 'notify'] },
];

/** Bucket plugins into ordered nav groups, hiding empty groups and sweeping any unmatched
 *  (unknown/custom) plugins into a trailing "other" group so nothing disappears. */
function groupPlugins(plugins: Plugin[]): { key: string; items: Plugin[] }[] {
  const byId = new Map(plugins.map((p) => [p.id, p]));
  const used = new Set<string>();
  const groups: { key: string; items: Plugin[] }[] = [];
  for (const g of NAV_GROUPS) {
    const items = g.ids.map((id) => byId.get(id)).filter((p): p is Plugin => Boolean(p));
    items.forEach((p) => used.add(p.id));
    if (items.length) groups.push({ key: g.key, items });
  }
  const other = plugins.filter((p) => !used.has(p.id));
  if (other.length) groups.push({ key: 'other', items: other });
  return groups;
}

// Collapsed nav groups persist across reloads (set of group keys).
const NAV_COLLAPSE_KEY = 'sbx_nav_collapsed';
function loadCollapsedGroups(): Set<string> {
  try {
    const raw = typeof localStorage !== 'undefined' ? localStorage.getItem(NAV_COLLAPSE_KEY) : null;
    if (raw) return new Set(JSON.parse(raw) as string[]);
  } catch {
    /* ignore malformed/unavailable storage */
  }
  return new Set();
}
function saveCollapsedGroups(groups: Set<string>): void {
  try {
    localStorage.setItem(NAV_COLLAPSE_KEY, JSON.stringify([...groups]));
  } catch {
    /* ignore */
  }
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
      title={`${title} · ${code}`}
      style={`--item-accent:${visual.accent}`}
      onClick={(e) => {
        e.preventDefault();
        navigate(target);
      }}
    >
      <span class="nav-icon" aria-hidden="true">
        <NavIcon name={visual.icon} />
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
  const [collapsed, setCollapsed] = useState<Set<string>>(loadCollapsedGroups);
  const toggleGroup = (key: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      saveCollapsedGroups(next);
      return next;
    });
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
        <NavLink
          target="/mcp"
          active={route === '/mcp'}
          title={t('mcp.title')}
          code="mcp"
          visual={navVisual('mcp')}
        />
      </div>
      {groupPlugins(plugins).map((group) => {
        const isCollapsed = collapsed.has(group.key);
        return (
          <div class="nav-section" key={group.key}>
            <button
              type="button"
              class="nav-label nav-label-toggle"
              aria-expanded={!isCollapsed}
              onClick={() => toggleGroup(group.key)}
            >
              <span class="nav-label-main">
                <span class={`nav-chevron ${isCollapsed ? 'collapsed' : ''}`} aria-hidden="true">▾</span>
                <span>{t(`nav.group.${group.key}`)}</span>
              </span>
            </button>
            {isCollapsed
              ? null
              : group.items.map((p) => {
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
        );
      })}
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
  const [client, setClient] = useState<'claude' | 'codex' | 'cursor'>('claude');
  // Claude Code & Cursor share the mcpServers JSON shape; Codex uses ~/.codex/config.toml (TOML).
  const jsonConfig = JSON.stringify(
    { mcpServers: { sandbox: { command: 'npx', args: ['-y', 'sandbox-mcp'], env } } },
    null,
    2,
  );
  const tomlEnv = Object.entries(env)
    .map(([k, v]) => `${k} = "${v}"`)
    .join(', ');
  const tomlConfig = `[mcp_servers.sandbox]\ncommand = "npx"\nargs = ["-y", "sandbox-mcp"]\nenv = { ${tomlEnv} }`;
  const clients = {
    claude: { label: 'Claude Code', loc: t('mcp.loc.claude'), code: jsonConfig },
    codex: { label: 'Codex', loc: t('mcp.loc.codex'), code: tomlConfig },
    cursor: { label: 'Cursor', loc: t('mcp.loc.cursor'), code: jsonConfig },
  } as const;
  const sel = clients[client];

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
            <CopyButton text={sel.code} />
          </div>
          <p>{t('mcp.step2.sub')}</p>
          <div class="seg-toggle" style="margin-bottom:10px">
            {(['claude', 'codex', 'cursor'] as const).map((c) => (
              <button
                key={c}
                class={client === c ? 'on' : ''}
                aria-pressed={client === c}
                onClick={() => setClient(c)}
              >
                {clients[c].label}
              </button>
            ))}
          </div>
          <div style="font-size:11px;opacity:0.6;margin-bottom:6px;font-family:var(--mono,monospace)">{sel.loc}</div>
          <pre class="mcp-code">{sel.code}</pre>
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
