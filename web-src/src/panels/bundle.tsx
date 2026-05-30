import { useCallback, useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { BundleSummary, MachOInfo, Provisioning, BundlePrivacy, SecurityReport } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { FileBrowser } from './FileBrowser';
import { formatBytes } from '../util/format';

function dateStr(sec?: number): string {
  if (!sec) return '—';
  return new Date(sec * 1000).toLocaleString();
}

export function BundlePanel() {
  const { t } = useI18n();
  const [summary, setSummary] = useState<BundleSummary | null>(null);
  const [macho, setMacho] = useState<MachOInfo | null>(null);
  const [prov, setProv] = useState<Provisioning | null>(null);
  const [privacy, setPrivacy] = useState<BundlePrivacy | null>(null);
  const [security, setSecurity] = useState<SecurityReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback((signal?: AbortSignal) => {
    setLoading(true);
    setError(null);
    // Independent fetches: one failing shouldn't blank the others.
    api
      .bundleSummary(signal)
      .then(setSummary)
      .catch((e: unknown) => {
        if (!signal?.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      })
      .finally(() => {
        if (!signal?.aborted) setLoading(false);
      });
    api.bundleMacho(signal).then(setMacho).catch(() => {});
    api.bundleSecurity(signal).then(setSecurity).catch(() => {});
    api.bundleProvisioning(signal).then(setProv).catch(() => {});
    api.bundlePrivacy(signal).then(setPrivacy).catch(() => {});
  }, []);

  useEffect(() => {
    const ctrl = new AbortController();
    load(ctrl.signal);
    return () => ctrl.abort();
  }, [load]);

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('bundle.title')}</h2>
        <div class="spacer" />
        <button class="btn" onClick={() => load()}>
          {t('bundle.reload')}
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}
      {loading && !summary ? <Loading labelKey="bundle.loading" /> : null}

      {summary && summary.supported !== false ? (
        <div class="bundle-grid">
          {/* Summary */}
          <section class="bundle-card">
            <div class="bundle-card-head">
              {summary.icon ? <img class="bundle-icon" src={`data:image/png;base64,${summary.icon}`} alt="" /> : null}
              <div>
                <div class="bundle-name">{summary.displayName ?? summary.bundleId ?? '—'}</div>
                <div class="muted mono">{summary.bundleId ?? '—'}</div>
              </div>
            </div>
            <dl class="bundle-dl">
              <dt>{t('bundle.version')}</dt>
              <dd>
                {summary.shortVersion ?? '—'} <span class="muted">({summary.build ?? '—'})</span>
              </dd>
              <dt>{t('bundle.minOS')}</dt>
              <dd>{summary.minimumOSVersion ?? '—'}</dd>
              <dt>{t('bundle.platform')}</dt>
              <dd>
                {summary.platform ?? '—'} <span class="muted">{summary.sdkName ?? ''}</span>
              </dd>
              <dt>{t('bundle.families')}</dt>
              <dd>
                {summary.deviceFamilies.length
                  ? summary.deviceFamilies.map((f) => (
                      <span key={f} class="chip-sm">
                        {f}
                      </span>
                    ))
                  : '—'}
              </dd>
              <dt>{t('bundle.path')}</dt>
              <dd class="mono break">{summary.bundlePath ?? '—'}</dd>
            </dl>
          </section>

          {/* Mach-O */}
          <section class="bundle-card">
            <div class="section-title">{t('bundle.sec.macho')}</div>
            {macho && macho.supported ? (
              <>
                <div class="bundle-sub">
                  <span class="chip-sm">{macho.fat ? t('bundle.macho.fat') : t('bundle.macho.thin')}</span>
                  <span class="muted">{formatBytes(macho.fileSize)}</span>
                </div>
                <table class="headers">
                  <tbody>
                    {macho.slices.map((s, i) => (
                      <tr key={i}>
                        <td class="hk">
                          {s.cpuType} <span class="muted">{s.cpuSubtype}</span>
                        </td>
                        <td class="hv">
                          <span class={`chip-sm ${s.encrypted ? 'danger' : 'ok'}`}>
                            {s.encrypted ? t('bundle.macho.encrypted') : t('bundle.macho.decrypted')}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </>
            ) : (
              <div class="muted">{t('bundle.macho.none')}</div>
            )}
          </section>

          {/* Security check */}
          <section class="bundle-card">
            <div class="section-title">{t('bundle.sec.security')}</div>
            {security && security.supported ? (
              <>
                <div class={`sec-score grade-${security.grade}`}>
                  <span class="sec-grade">{security.grade}</span>
                  <span class="sec-num">{security.score}<span class="muted">/100</span></span>
                  {security.arch ? <span class="muted mono">{security.arch}</span> : null}
                </div>
                <table class="headers sec-checks">
                  <tbody>
                    {security.checks.map((c) => (
                      <tr key={c.id}>
                        <td class="hk">
                          <span class={`sec-dot ${c.status}`} aria-hidden="true" />
                          {c.title}
                        </td>
                        <td class="hv muted">{c.detail}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </>
            ) : (
              <div class="muted">{t('bundle.sec.security.none')}</div>
            )}
          </section>

          {/* Provisioning */}
          <section class="bundle-card">
            <div class="section-title">{t('bundle.sec.provisioning')}</div>
            {prov && prov.present ? (
              prov.parseError ? (
                <div class="muted">
                  {t('bundle.prov.error')}: {prov.parseError}
                </div>
              ) : (
                <>
                  <dl class="bundle-dl">
                    <dt>{t('bundle.prov.team')}</dt>
                    <dd>
                      {prov.teamName ?? '—'} <span class="muted mono">{prov.teamIdentifier ?? ''}</span>
                    </dd>
                    <dt>{t('bundle.prov.appId')}</dt>
                    <dd class="mono break">{prov.appId ?? prov.appIdName ?? '—'}</dd>
                    <dt>{t('bundle.prov.created')}</dt>
                    <dd>{dateStr(prov.creationDate)}</dd>
                    <dt>{t('bundle.prov.expires')}</dt>
                    <dd>
                      {dateStr(prov.expirationDate)}
                      {prov.expired ? <span class="chip-sm danger">{t('bundle.prov.expired')}</span> : null}
                    </dd>
                    <dt>{t('bundle.prov.type')}</dt>
                    <dd>{prov.isDistribution ? t('bundle.prov.distribution') : t('bundle.prov.development')}</dd>
                    <dt>{t('bundle.prov.devices')}</dt>
                    <dd>{prov.provisionedDeviceCount ?? '—'}</dd>
                  </dl>
                  {prov.entitlements ? (
                    <>
                      <div class="section-title">{t('bundle.prov.entitlements')}</div>
                      <pre class="body">{JSON.stringify(prov.entitlements, null, 2)}</pre>
                    </>
                  ) : null}
                </>
              )
            ) : (
              <div class="muted">{t('bundle.prov.none')}</div>
            )}
          </section>

          {/* Privacy / permissions */}
          <section class="bundle-card">
            <div class="section-title">{t('bundle.sec.privacy')}</div>
            {privacy ? (
              <>
                {privacy.usageDescriptions.length ? (
                  <table class="headers">
                    <tbody>
                      {privacy.usageDescriptions.map((u) => (
                        <tr key={u.key}>
                          <td class="hk mono">{u.key.replace(/UsageDescription$/, '')}</td>
                          <td class="hv">{u.purpose}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : null}
                {privacy.urlSchemes.length ? (
                  <div class="bundle-sub">
                    <span class="muted">{t('bundle.priv.schemes')}</span>
                    {privacy.urlSchemes.map((s) => (
                      <span key={s} class="chip-sm">
                        {s}
                      </span>
                    ))}
                  </div>
                ) : null}
                {privacy.backgroundModes.length ? (
                  <div class="bundle-sub">
                    <span class="muted">{t('bundle.priv.background')}</span>
                    {privacy.backgroundModes.map((m) => (
                      <span key={m} class="chip-sm">
                        {m}
                      </span>
                    ))}
                  </div>
                ) : null}
                {privacy.ats ? (
                  <div class="bundle-sub">
                    <span class="muted">{t('bundle.priv.ats')}</span>
                    {privacy.ats.allowsArbitraryLoads ? (
                      <span class="chip-sm danger">{t('bundle.priv.atsArbitrary')}</span>
                    ) : null}
                    {privacy.ats.exceptionDomains.map((d) => (
                      <span key={d} class="chip-sm">
                        {d}
                      </span>
                    ))}
                  </div>
                ) : null}
                {!privacy.usageDescriptions.length &&
                !privacy.urlSchemes.length &&
                !privacy.backgroundModes.length &&
                !privacy.ats ? (
                  <div class="muted">{t('bundle.priv.none')}</div>
                ) : null}
              </>
            ) : (
              <div class="muted">—</div>
            )}
          </section>
        </div>
      ) : null}

      {summary?.bundlePath ? (
        <section class="bundle-card bundle-files">
          <div class="section-title">{t('bundle.sec.payload')}</div>
          <FileBrowser
            rootPath={summary.bundlePath}
            rootName={summary.displayName ? `${summary.displayName}.app` : 'Payload'}
            readOnly
          />
        </section>
      ) : null}
    </div>
  );
}
