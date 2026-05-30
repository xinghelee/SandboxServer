import type { BundleSummary, MachOInfo, BundlePrivacy, SecurityReport } from '../api/types';
import { useI18n } from '../i18n';
import { formatBytes } from '../util/format';

/** Shared presentational cards for the app-bundle inspector — used both for the live device bundle
 *  and for an uploaded IPA report, so the two render identically. Each card is null-safe. */
export function SummaryCard({ summary }: { summary: BundleSummary }) {
  const { t } = useI18n();
  return (
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
  );
}

export function MachoCard({ macho }: { macho: MachOInfo | null }) {
  const { t } = useI18n();
  return (
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
  );
}

export function SecurityCard({ security }: { security: SecurityReport | null }) {
  const { t } = useI18n();
  return (
    <section class="bundle-card">
      <div class="section-title">{t('bundle.sec.security')}</div>
      {security && security.supported ? (
        <>
          <div class={`sec-score grade-${security.grade}`}>
            <span class="sec-grade">{security.grade}</span>
            <span class="sec-num">
              {security.score}
              <span class="muted">/100</span>
            </span>
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
  );
}

export function PrivacyCard({ privacy }: { privacy: BundlePrivacy | null }) {
  const { t } = useI18n();
  const empty =
    privacy &&
    !privacy.usageDescriptions.length &&
    !privacy.urlSchemes.length &&
    !privacy.backgroundModes.length &&
    !privacy.ats;
  return (
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
          {empty ? <div class="muted">{t('bundle.priv.none')}</div> : null}
        </>
      ) : (
        <div class="muted">—</div>
      )}
    </section>
  );
}
