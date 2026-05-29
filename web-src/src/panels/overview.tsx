import { useEffect, useState } from 'preact/hooks';
import { api } from '../api/client';
import type { Health, Plugin, ScreenInfo } from '../api/types';
import { useI18n, hasKey, moduleName } from '../i18n';
import { navigate } from '../router';

const THUMB_POLL_MS = 700; // gentle live thumbnail (~1.4 fps)

/** Per-module stat: how to fetch a quick count for a plugin id, and the descriptor under it. */
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
 * Landing dashboard — a debug "command deck". A terminal status line (who the device/app is, from
 * /healthz), the current app screen framed as a live read-only viewport (click to open the full
 * Screen panel), and one channel readout per active plugin with a quick count. Pure aggregation over
 * existing endpoints — no new wire contract.
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
          /* leave the channel showing its placeholder */
        });
    }
    return () => ctrl.abort();
  }, [plugins]);

  // Live screen thumbnail — only polls when the device reports a capturable screen.
  useEffect(() => {
    if (!pluginFor('screen')) {
      setScreenChecked(true);
      return;
    }
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      try {
        const res = await api.screenFrame(420, 0.62);
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

  const debug = health?.buildConfig === 'debug';
  const identity: Array<[string, string]> = health
    ? [
        [t('home.id.app'), health.appBundleId],
        [t('home.id.device'), health.deviceName],
        [t('home.id.binding'), health.bindingPolicy],
        [t('home.id.api'), health.apiVersion],
      ]
    : [];

  const channels = plugins.filter((p) => p.id !== 'screen' && p.panelKey !== 'screen');
  const dim = screen ? `${Math.round(screen.width)}×${Math.round(screen.height)} @${screen.scale}x` : '';

  return (
    <div class="panel ov">
      {/* Terminal status line */}
      <header class="ov-head">
        <div class="ov-prompt">
          <span class="ov-sigil">▍</span>
          <span class="ov-host">{health?.deviceName ?? 'device'}</span>
          <span class="ov-path">{t('prompt.path')}</span>
          <span class="ov-cmd">status</span>
          <span class="ov-caret" aria-hidden="true" />
        </div>
        <div class="ov-tags">
          <span class={`ov-tag ${health ? (debug ? 'ok' : 'warn') : ''}`}>
            {t('hdr.build')} <b>{health?.buildConfig ?? '—'}</b>
          </span>
          <span class="ov-tag">
            {t('hdr.binding')} <b>{health?.bindingPolicy ?? '—'}</b>
          </span>
          <span class="ov-tag">
            {t('home.id.api')} <b>{health?.apiVersion ?? '—'}</b>
          </span>
        </div>
      </header>

      <div class="ov-deck">
        {/* Live viewport */}
        <section class="ov-panel ov-view" data-label={t('home.screen.title')}>
          <div class="ov-view-bar">
            {screenSupported ? (
              <span class="ov-live">
                <i class="led" />
                {t('home.live')}
              </span>
            ) : (
              <span class="ov-live off">○ {t('ws.offline')}</span>
            )}
            {dim ? <span class="ov-view-dim">{dim}</span> : null}
            <div class="spacer" />
            {screenSupported ? (
              <button class="ov-open" onClick={() => open('screen')}>
                {t('home.screen.open')} →
              </button>
            ) : null}
          </div>
          <div class="ov-view-frame">
            {screenChecked && !screenSupported ? (
              <div class="ov-view-off muted">{t('home.screen.off')}</div>
            ) : frameUrl ? (
              <button class="ov-view-thumb" onClick={() => open('screen')} title={t('home.screen.open')}>
                <img src={frameUrl} alt={t('home.screen.title')} draggable={false} />
                <span class="ov-scan" aria-hidden="true" />
              </button>
            ) : (
              <div class="ov-view-off muted">{t('home.screen.waiting')}</div>
            )}
          </div>
        </section>

        {/* Device identity readout */}
        <section class="ov-panel ov-readout" data-label={t('home.identity')}>
          <dl class="ov-kv">
            {identity.length === 0 ? <div class="ov-kv-row"><dd class="mono muted">…</dd></div> : null}
            {identity.map(([k, v]) => (
              <div key={k} class="ov-kv-row">
                <dt>{k}</dt>
                <dd class="mono">{v}</dd>
              </div>
            ))}
          </dl>
        </section>
      </div>

      {/* Module channels */}
      <section class="ov-panel ov-channels" data-label={t('home.modules')}>
        <div class="ov-chan-grid">
          {channels.map((p, i) => (
            <button
              key={p.id}
              class="ov-chan"
              style={`animation-delay:${80 + i * 55}ms`}
              onClick={() => navigate(`/${p.panelKey || p.id}`)}
            >
              <span class="ov-chan-num">{stats[p.id] ?? '·'}</span>
              <span class="ov-chan-name">{moduleName(p.id, p.title)}</span>
              <span class="ov-chan-meta">
                <span class="ov-chan-id">{p.id}</span>
                {hasKey(`home.stat.${p.id}`) ? <span class="ov-chan-sub">{t(`home.stat.${p.id}`)}</span> : null}
              </span>
              <span class="ov-chan-go" aria-hidden="true">→</span>
            </button>
          ))}
        </div>
      </section>
    </div>
  );
}
