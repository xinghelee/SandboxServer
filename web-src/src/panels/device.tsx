import type { ComponentChildren } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DeviceInfo } from '../api/types';

const CARD =
  'border:1px solid rgba(128,128,128,0.22);border-radius:10px;padding:12px 14px;' +
  'background:rgba(128,128,128,0.04);display:flex;flex-direction:column;gap:7px;min-width:0';

function fmtMB(mb: number | null | undefined): string {
  if (mb == null) return '—';
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div style="display:flex;justify-content:space-between;gap:12px;font-size:12.5px">
      <span style="opacity:0.6">{label}</span>
      <span style="font-variant-numeric:tabular-nums;text-align:right;word-break:break-word">{value || '—'}</span>
    </div>
  );
}

function Card({ title, children }: { title: string; children: ComponentChildren }) {
  return (
    <div style={CARD}>
      <div style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7;margin-bottom:2px">{title}</div>
      {children}
    </div>
  );
}

/** One-shot device + runtime info snapshot. Read-only; refreshes on demand. */
export function DevicePanel() {
  const [info, setInfo] = useState<DeviceInfo | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = (signal?: AbortSignal) => {
    setError(null);
    api
      .deviceInfo(signal)
      .then(setInfo)
      .catch((e: unknown) => {
        if (!signal?.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      });
  };

  useEffect(() => {
    const ctrl = new AbortController();
    load(ctrl.signal);
    return () => ctrl.abort();
  }, []);

  const offset = info ? `UTC${info.locale.utcOffsetSeconds >= 0 ? '+' : ''}${(info.locale.utcOffsetSeconds / 3600).toFixed(2).replace(/\.00$/, '')}` : '';

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>Device</h2>
        <div class="spacer" />
        <button
          onClick={() => load()}
          style="font-size:11px;padding:4px 10px;border-radius:6px;border:1px solid rgba(128,128,128,0.3);background:transparent;color:inherit;cursor:pointer"
        >
          refresh
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {!info ? (
        <div style="padding:24px;opacity:0.6">Loading…</div>
      ) : (
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;padding:12px">
          <Card title="App">
            <Field label="name" value={info.app.name ?? ''} />
            <Field label="bundle id" value={info.app.bundleId ?? ''} />
            <Field label="version" value={info.app.version ? `${info.app.version} (${info.app.build ?? '—'})` : ''} />
          </Card>

          <Card title="OS">
            <Field label="platform" value={info.os.platform} />
            <Field label="name" value={info.os.name} />
            <Field label="version" value={info.os.version} />
          </Card>

          <Card title="Hardware">
            <Field label="machine" value={info.hardware.machine} />
            <Field label="model" value={info.hardware.model ?? ''} />
            <Field label="name" value={info.hardware.name ?? ''} />
            <Field label="idiom" value={info.hardware.idiom ?? ''} />
          </Card>

          <Card title="Locale">
            <Field label="locale" value={info.locale.identifier} />
            <Field label="region" value={info.locale.region ?? ''} />
            <Field label="languages" value={info.locale.languages.slice(0, 3).join(', ')} />
            <Field label="time zone" value={`${info.locale.timeZone} (${offset})`} />
            <Field label="24-hour" value={info.locale.uses24Hour ? 'yes' : 'no'} />
          </Card>

          {info.screen ? (
            <Card title="Screen">
              <Field label="size" value={`${Math.round(info.screen.width)} × ${Math.round(info.screen.height)} pt`} />
              <Field label="scale" value={`${info.screen.scale}× (native ${info.screen.nativeScale}×)`} />
              {info.screen.safeArea ? (
                <Field
                  label="safe area"
                  value={`T${Math.round(info.screen.safeArea.top)} B${Math.round(info.screen.safeArea.bottom)} L${Math.round(info.screen.safeArea.left)} R${Math.round(info.screen.safeArea.right)}`}
                />
              ) : null}
            </Card>
          ) : null}

          {info.battery ? (
            <Card title="Battery">
              <Field label="level" value={info.battery.level >= 0 ? `${Math.round(info.battery.level * 100)}%` : 'unknown'} />
              <Field label="state" value={info.battery.state} />
              <Field label="low power mode" value={info.battery.lowPowerMode ? 'on' : 'off'} />
            </Card>
          ) : null}

          <Card title="Memory & Disk">
            <Field label="physical RAM" value={fmtMB(info.memory.physicalMB)} />
            <Field label="disk total" value={fmtMB(info.disk.totalMB)} />
            <Field label="disk free" value={fmtMB(info.disk.availableMB)} />
          </Card>

          <Card title="Process">
            <Field label="processors" value={`${info.process.activeProcessorCount} / ${info.process.processorCount} active`} />
            <Field label="thermal" value={info.process.thermalState} />
            <Field label="uptime" value={`${Math.round(info.process.uptimeSeconds / 60)} min`} />
          </Card>
        </div>
      )}
    </div>
  );
}
