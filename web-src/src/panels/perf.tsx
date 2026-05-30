import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import { socket } from '../api/ws';
import type { PerfSample, WsServerMessage } from '../api/types';
import { useI18n } from '../i18n';

// ~90s of history at the server's 2 samples/s cadence.
const MAX_SAMPLES = 180;

type Tone = 'ok' | 'warn' | 'bad' | 'dim';
const TONE: Record<Tone, string> = {
  ok: '#3fb950',
  warn: '#d29922',
  bad: '#f85149',
  dim: 'var(--ink-dim)',
};

const fpsTone = (v: number | null): Tone => (v == null ? 'dim' : v >= 55 ? 'ok' : v >= 30 ? 'warn' : 'bad');
const cpuTone = (v: number): Tone => (v < 60 ? 'ok' : v < 150 ? 'warn' : 'bad');
const memTone = (p: number | null): Tone => (p == null ? 'dim' : p < 50 ? 'ok' : p < 75 ? 'warn' : 'bad');
const thermalTone = (s: string): Tone =>
  s === 'nominal' ? 'ok' : s === 'fair' ? 'warn' : s === 'serious' || s === 'critical' ? 'bad' : 'dim';

const CARD_STYLE =
  'border:1px solid rgba(128,128,128,0.22);border-radius:10px;padding:12px 14px;' +
  'background:rgba(128,128,128,0.04);display:flex;flex-direction:column;gap:8px;min-width:0';

/** Dependency-free right-aligned sparkline: an SVG polyline + faint fill, scaled to `max`. */
function Sparkline({ values, max, color }: { values: number[]; max: number; color: string }) {
  const W = 240;
  const H = 46;
  if (values.length < 2) {
    return <svg viewBox={`0 0 ${W} ${H}`} style="width:100%;height:46px;display:block" aria-hidden="true" />;
  }
  const hi = Math.max(max, ...values) || 1;
  const step = W / (MAX_SAMPLES - 1);
  const offset = W - (values.length - 1) * step; // newest sample pinned to the right edge
  const pts = values
    .map((v, i) => `${(offset + i * step).toFixed(1)},${(H - (Math.min(v, hi) / hi) * (H - 4) - 2).toFixed(1)}`)
    .join(' ');
  return (
    <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" style="width:100%;height:46px;display:block" aria-hidden="true">
      <polygon points={`${offset.toFixed(1)},${H} ${pts} ${W},${H}`} fill={color} opacity="0.12" />
      <polyline points={pts} fill="none" stroke={color} stroke-width="1.5" stroke-linejoin="round" />
    </svg>
  );
}

function Stat(props: {
  label: string;
  value: string;
  unit?: string;
  sub?: string;
  tone: Tone;
  values: number[];
  max: number;
}) {
  const color = TONE[props.tone];
  return (
    <div style={CARD_STYLE}>
      <div style="display:flex;align-items:center;justify-content:space-between">
        <span style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7">{props.label}</span>
        <span style={`width:8px;height:8px;border-radius:50%;background:${color}`} />
      </div>
      <div style="display:flex;align-items:baseline;gap:5px">
        <b style={`font-size:30px;font-variant-numeric:tabular-nums;line-height:1;color:${color}`}>{props.value}</b>
        {props.unit ? <span style="font-size:12px;opacity:0.6">{props.unit}</span> : null}
      </div>
      <Sparkline values={props.values} max={props.max} color={color} />
      <div style="font-size:11px;opacity:0.6;min-height:14px">{props.sub ?? ''}</div>
    </div>
  );
}

/**
 * Live performance HUD. An initial snapshot from GET /perf fills the cards, then every sample
 * streams over the `perf` WS channel (FPS, CPU %, memory footprint, thermal). FPS/hitch are null
 * on non-UIKit hosts — the FPS card shows n/a there.
 */
export function PerfPanel() {
  const { t } = useI18n();
  const [samples, setSamples] = useState<PerfSample[]>([]);
  const [latest, setLatest] = useState<PerfSample | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .perfSnapshot(ctrl.signal)
      .then((s) => setLatest(s))
      .catch((e: unknown) => {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      });
    return () => ctrl.abort();
  }, []);

  useEffect(() => {
    const unsub = socket.subscribe('perf', (msg: WsServerMessage) => {
      if (msg.type !== 'perf.sample') return;
      const s = msg.payload as unknown as PerfSample;
      setLatest(s);
      setSamples((prev) => {
        const next = [...prev, s];
        return next.length > MAX_SAMPLES ? next.slice(next.length - MAX_SAMPLES) : next;
      });
    });
    return unsub;
  }, []);

  const hasFps = latest?.supported ?? true;
  const fps = samples.map((s) => s.fps ?? 0);
  const cpu = samples.map((s) => s.cpu);
  const mem = samples.map((s) => s.memMB);
  const memMax = Math.max(64, ...(mem.length ? mem : [latest?.memMB ?? 64]));
  const thermalColor = TONE[latest ? thermalTone(latest.thermal) : 'dim'];

  let fpsSub: string | undefined;
  if (!hasFps) fpsSub = t('perf.fps.na');
  else if (latest?.hitchMs != null) fpsSub = t('perf.hitch', { ms: latest.hitchMs.toFixed(1) });

  let memSub: string | undefined;
  if (latest?.memPct != null) memSub = `${latest.memPct.toFixed(0)}% · ${Math.round(latest.memLimitMB)} MB`;

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('perf.title')}</h2>
        {latest ? <span class="count-chip">{t('perf.live')}</span> : null}
        <div class="spacer" />
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px;padding:12px">
        <Stat
          label={t('perf.fps')}
          value={hasFps && latest?.fps != null ? String(Math.round(latest.fps)) : '—'}
          unit={hasFps ? 'fps' : undefined}
          sub={fpsSub}
          tone={fpsTone(hasFps ? (latest?.fps ?? null) : null)}
          values={hasFps ? fps : []}
          max={60}
        />
        <Stat
          label={t('perf.cpu')}
          value={latest ? latest.cpu.toFixed(0) : '—'}
          unit="%"
          tone={latest ? cpuTone(latest.cpu) : 'dim'}
          values={cpu}
          max={100}
        />
        <Stat
          label={t('perf.mem')}
          value={latest ? latest.memMB.toFixed(0) : '—'}
          unit="MB"
          sub={memSub}
          tone={memTone(latest?.memPct ?? null)}
          values={mem}
          max={memMax}
        />
        <div style={CARD_STYLE}>
          <div style="display:flex;align-items:center;justify-content:space-between">
            <span style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7">{t('perf.thermal')}</span>
            <span style={`width:8px;height:8px;border-radius:50%;background:${thermalColor}`} />
          </div>
          <div style="display:flex;align-items:baseline;gap:5px">
            <b style={`font-size:30px;line-height:1;color:${thermalColor}`}>
              {latest ? t(`perf.thermal.${latest.thermal}`) : '—'}
            </b>
          </div>
          <div style="font-size:11px;opacity:0.6;min-height:14px">{t('perf.thermal.sub')}</div>
        </div>
      </div>

      <div style="font-size:11px;opacity:0.55;padding:0 14px 14px">{t('perf.note')}</div>
    </div>
  );
}
