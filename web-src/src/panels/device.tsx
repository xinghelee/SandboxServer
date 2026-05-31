import type { ComponentChildren } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DeviceInfo } from '../api/types';
import { useI18n } from '../i18n';

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
  const { t } = useI18n();
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
        <h2>{t('device.title')}</h2>
        <div class="spacer" />
        <button
          onClick={() => load()}
          style="font-size:11px;padding:4px 10px;border-radius:6px;border:1px solid rgba(128,128,128,0.3);background:transparent;color:inherit;cursor:pointer"
        >
          {t('act.refresh')}
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {!info ? (
        <div style="padding:24px;opacity:0.6">{t('act.loading')}</div>
      ) : (
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;padding:12px">
          <Card title={t('device.card.app')}>
            <Field label={t('device.f.name')} value={info.app.name ?? ''} />
            <Field label={t('device.f.bundleId')} value={info.app.bundleId ?? ''} />
            <Field label={t('device.f.version')} value={info.app.version ? `${info.app.version} (${info.app.build ?? '—'})` : ''} />
          </Card>

          <Card title={t('device.card.os')}>
            <Field label={t('device.f.platform')} value={info.os.platform} />
            <Field label={t('device.f.name')} value={info.os.name} />
            <Field label={t('device.f.version')} value={info.os.version} />
          </Card>

          <Card title={t('device.card.hardware')}>
            <Field label={t('device.f.machine')} value={info.hardware.machine} />
            <Field label={t('device.f.model')} value={info.hardware.model ?? ''} />
            <Field label={t('device.f.name')} value={info.hardware.name ?? ''} />
            <Field label={t('device.f.idiom')} value={info.hardware.idiom ?? ''} />
          </Card>

          <Card title={t('device.card.locale')}>
            <Field label={t('device.f.locale')} value={info.locale.identifier} />
            <Field label={t('device.f.region')} value={info.locale.region ?? ''} />
            <Field label={t('device.f.languages')} value={info.locale.languages.slice(0, 3).join(', ')} />
            <Field label={t('device.f.timezone')} value={`${info.locale.timeZone} (${offset})`} />
            <Field label={t('device.f.h24')} value={info.locale.uses24Hour ? t('device.v.yes') : t('device.v.no')} />
          </Card>

          {info.screen ? (
            <Card title={t('device.card.screen')}>
              <Field label={t('device.f.size')} value={`${Math.round(info.screen.width)} × ${Math.round(info.screen.height)} pt`} />
              <Field label={t('device.f.scale')} value={`${info.screen.scale}× (native ${info.screen.nativeScale}×)`} />
              {info.screen.safeArea ? (
                <Field
                  label={t('device.f.safearea')}
                  value={`T${Math.round(info.screen.safeArea.top)} B${Math.round(info.screen.safeArea.bottom)} L${Math.round(info.screen.safeArea.left)} R${Math.round(info.screen.safeArea.right)}`}
                />
              ) : null}
            </Card>
          ) : null}

          {info.battery ? (
            <Card title={t('device.card.battery')}>
              <Field label={t('device.f.level')} value={info.battery.level >= 0 ? `${Math.round(info.battery.level * 100)}%` : t('device.v.unknown')} />
              <Field label={t('device.f.state')} value={info.battery.state} />
              <Field label={t('device.f.lowpower')} value={info.battery.lowPowerMode ? t('device.v.on') : t('device.v.off')} />
            </Card>
          ) : null}

          <Card title={t('device.card.memdisk')}>
            <Field label={t('device.f.ram')} value={fmtMB(info.memory.physicalMB)} />
            <Field label={t('device.f.disktotal')} value={fmtMB(info.disk.totalMB)} />
            <Field label={t('device.f.diskfree')} value={fmtMB(info.disk.availableMB)} />
          </Card>

          <Card title={t('device.card.process')}>
            <Field
              label={t('device.f.processors')}
              value={t('device.v.active', { a: info.process.activeProcessorCount, t: info.process.processorCount })}
            />
            <Field label={t('device.f.thermal')} value={info.process.thermalState} />
            <Field label={t('device.f.uptime')} value={t('device.v.min', { n: Math.round(info.process.uptimeSeconds / 60) })} />
          </Card>
        </div>
      )}
    </div>
  );
}
