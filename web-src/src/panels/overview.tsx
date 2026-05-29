import { useEffect, useState } from 'preact/hooks';
import { api } from '../api/client';
import type { Health, Plugin, ScreenInfo } from '../api/types';
import { useI18n, hasKey, moduleName } from '../i18n';
import { navigate } from '../router';

const THUMB_POLL_MS = 700; // gentle live thumbnail (~1.4 fps)

/** Per-module stat: how to fetch a quick count for a plugin id. */
const STAT_LOADERS: Record<string, (signal: AbortSignal) => Promise<string>> = {
  net: async (s) => {
    const r = await api.netRequests({ limit: 200 }, s);
    return `${r.items.length}${r.nextCursor ? '+' : ''}`;
  },
  logs: async (s) => {
    const r = await api.logs({ limit: 200 }, s);
    return `${r.items.length}${r.nextCursor ? '+' : ''}`;
  },
  db: async (s) => String((await api.databases(s)).items.length),
  fs: async (s) => String((await api.fsRoots(s)).items.length),
};

/**
 * Landing dashboard — information-first. Left: a large live HD mirror of the app screen (click to
 * open the full Screen panel). Top-right: app info. Bottom-right: quick entry points into each
 * plugin. Build/binding live in the top header, so they're intentionally not repeated here. Pure
 * aggregation over existing endpoints — no new wire contract.
 */
export function OverviewPanel({ health, plugins }: { health: Health | null; plugins: Plugin[] }) {
  const { t } = useI18n();
  const [stats, setStats] = useState<Record<string, string>>({});
  const [screen, setScreen] = useState<ScreenInfo | null>(null);
  const [screenChecked, setScreenChecked] = useState(false);
  const [frameUrl, setFrameUrl] = useState<string | null>(null);

  const pluginFor = (id: string) => plugins.find((p) => p.id === id || p.panelKey === id);
  const open = (id: string) => {
    const p = pluginFor(id);
    if (p) navigate(`/${p.panelKey || p.id}`);
  };
  const screenSupported = screen?.supported === true;

  // Quick per-module counts, fetched once (independent so one failing doesn't blank the others).
  useEffect(() => {
    const ctrl = new AbortController();
    for (const p of plugins) {
      const load = STAT_LOADERS[p.id];
      if (!load) continue;
      load(ctrl.signal)
        .then((v) => setStats((s) => ({ ...s, [p.id]: v })))
        .catch(() => {
          /* leave the shortcut without a count */
        });
    }
    return () => ctrl.abort();
  }, [plugins]);

  // Live HD screen thumbnail — only polls when the device reports a capturable screen.
  useEffect(() => {
    if (!pluginFor('screen')) {
      setScreenChecked(true);
      return;
    }
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      try {
        const res = await api.screenFrame(720, 0.8); // high quality — this is the page's centerpiece
        const blob = await res.blob();
        if (cancelled) return;
        const url = URL.createObjectURL(blob);
        setFrameUrl((prev) => {
          if (prev) URL.revokeObjectURL(prev);
          return url;
        });
      } catch {
        /* transient — try again next tick */
      }
      if (!cancelled) timer = setTimeout(tick, THUMB_POLL_MS);
    };
    api
      .screenInfo()
      .then((info) => {
        if (cancelled) return;
        setScreen(info);
        setScreenChecked(true);
        if (info.supported) tick();
      })
      .catch(() => {
        if (!cancelled) setScreenChecked(true);
      });
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
      setFrameUrl((prev) => {
        if (prev) URL.revokeObjectURL(prev);
        return null;
      });
    };
  }, [plugins]);

  const appName = health?.appName || health?.appBundleId || 'app';
  const info: Array<[string, string]> = [];
  if (health) {
    const ver = health.appVersion
      ? `${health.appVersion}${health.appBuild ? ` (${health.appBuild})` : ''}`
      : null;
    if (ver) info.push([t('home.id.version'), ver]);
    const os = (health.osName || health.osVersion) ? `${health.osName ?? ''} ${health.osVersion ?? ''}`.trim() : null;
    if (os) info.push([t('home.id.os'), os]);
    if (health.deviceModel) info.push([t('home.id.model'), health.deviceModel]);
    info.push([t('home.id.device'), health.deviceName]);
    if (health.sdkVersion) info.push([t('home.id.sdk'), health.sdkVersion]);
    info.push([t('home.id.api'), health.apiVersion]);
    info.push([t('home.id.auth'), health.requiresAuth ? t('home.auth.yes') : t('home.auth.no')]);
  }
  const shortcuts = plugins.filter((p) => p.id !== 'screen' && p.panelKey !== 'screen');
  const dim = screen ? `${Math.round(screen.width)}×${Math.round(screen.height)} @${screen.scale}x` : '';

  return (
    <div class="panel ov">
      <div class="ov-bar">
        <h2>{t('home.title')}</h2>
        <span class="ov-host mono">{health?.deviceName ?? 'device'}</span>
        <div class="spacer" />
        {screenSupported ? (
          <span class="ov-live">
            <i class="led" />
            {t('home.live')}
          </span>
        ) : null}
      </div>

      <div class="ov-deck">
        {/* Left: large live HD screen */}
        <section class="ov-screen">
          <div class="ov-screen-head">
            <span class="ov-sec-title">{t('home.screen.title')}</span>
            {dim ? <span class="ov-dim">{dim}</span> : null}
            <div class="spacer" />
            {screenSupported ? (
              <button class="ov-open" onClick={() => open('screen')}>
                {t('home.screen.open')} →
              </button>
            ) : null}
          </div>
          {screenChecked && !screenSupported ? (
            <div class="ov-screen-off muted">{t('home.screen.off')}</div>
          ) : frameUrl ? (
            <button class="ov-screen-thumb" onClick={() => open('screen')} title={t('home.screen.open')}>
              <img src={frameUrl} alt={t('home.screen.title')} draggable={false} />
            </button>
          ) : (
            <div class="ov-screen-off muted">{t('home.screen.waiting')}</div>
          )}
        </section>

        {/* Top-right: app info */}
        <section class="ov-info">
          <div class="ov-sec-title">{t('home.identity')}</div>
          <div class="ov-app">
            {health?.appIcon ? (
              <img class="ov-app-icon" src={`data:image/png;base64,${health.appIcon}`} alt="" />
            ) : (
              <div class="ov-app-icon ph">{appName.slice(0, 1).toUpperCase()}</div>
            )}
            <div class="ov-app-meta">
              <div class="ov-app-name">{appName}</div>
              <div class="ov-app-bid mono">{health?.appBundleId ?? '—'}</div>
            </div>
          </div>
          <dl class="ov-kv">
            {info.map(([k, v]) => (
              <div key={k} class="ov-kv-row">
                <dt>{k}</dt>
                <dd class="mono">{v}</dd>
              </div>
            ))}
          </dl>
        </section>

        {/* Bottom-right: quick entries */}
        <section class="ov-quick">
          <div class="ov-sec-title">{t('home.shortcuts')}</div>
          <div class="ov-quick-grid">
            {shortcuts.map((p) => (
              <button key={p.id} class="ov-shortcut" onClick={() => navigate(`/${p.panelKey || p.id}`)}>
                <span class="ov-shortcut-top">
                  <span class="ov-shortcut-name">{moduleName(p.id, p.title)}</span>
                  <span class="ov-shortcut-count">{stats[p.id] ?? ''}</span>
                </span>
                <span class="ov-shortcut-sub">{hasKey(`home.stat.${p.id}`) ? t(`home.stat.${p.id}`) : p.id}</span>
              </button>
            ))}
          </div>
        </section>
      </div>
    </div>
  );
}
