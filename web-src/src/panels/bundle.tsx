import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { BundleSummary, MachOInfo, Provisioning, BundlePrivacy, SecurityReport } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { FileBrowser } from './FileBrowser';
import { SummaryCard, MachoCard, SecurityCard, PrivacyCard } from './BundleCards';
import { analyzeIpa, type IpaReport } from '../util/ipa/analyze';
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

  // Uploaded-IPA analysis (browser-side; independent of the device).
  const [ipa, setIpa] = useState<IpaReport | null>(null);
  const [ipaBusy, setIpaBusy] = useState(false);
  const [ipaError, setIpaError] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  const load = useCallback((signal?: AbortSignal) => {
    setLoading(true);
    setError(null);
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

  const analyze = useCallback(async (file: File) => {
    setIpaBusy(true);
    setIpaError(null);
    setIpa(null);
    try {
      setIpa(await analyzeIpa(file));
    } catch (e) {
      setIpaError(e instanceof Error ? e.message : String(e));
    } finally {
      setIpaBusy(false);
    }
  }, []);

  const onDrop = useCallback(
    (e: DragEvent) => {
      e.preventDefault();
      setDragOver(false);
      const file = e.dataTransfer?.files?.[0];
      if (file) void analyze(file);
    },
    [analyze],
  );

  const onPick = useCallback(
    (e: Event) => {
      const file = (e.target as HTMLInputElement).files?.[0];
      if (file) void analyze(file);
    },
    [analyze],
  );

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('bundle.title')}</h2>
        <div class="spacer" />
        {ipa || ipaError ? (
          <button
            class="btn"
            onClick={() => {
              setIpa(null);
              setIpaError(null);
            }}
          >
            {t('bundle.ipa.back')}
          </button>
        ) : null}
        {!ipa ? (
          <button class="btn" onClick={() => fileInput.current?.click()}>
            {t('bundle.ipa.choose')}
          </button>
        ) : null}
        {!ipa ? (
          <button class="btn" onClick={() => load()}>
            {t('bundle.reload')}
          </button>
        ) : null}
        <input
          ref={fileInput}
          type="file"
          accept=".ipa,.zip,application/octet-stream"
          style="display:none"
          onChange={onPick}
        />
      </div>

      {/* Drop zone — always available unless an analysis is showing. */}
      {!ipa && !ipaBusy ? (
        <div
          class={`ipa-drop ${dragOver ? 'over' : ''}`}
          onDragOver={(e) => {
            e.preventDefault();
            setDragOver(true);
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={onDrop}
          onClick={() => fileInput.current?.click()}
          role="button"
          tabIndex={0}
        >
          <span class="ipa-drop-ic" aria-hidden="true">
            ⬇
          </span>
          <span>{t('bundle.ipa.drop')}</span>
          <span class="muted">{t('bundle.ipa.dropHint')}</span>
        </div>
      ) : null}

      {ipaBusy ? <Loading labelKey="bundle.ipa.analyzing" /> : null}
      {ipaError ? <div class="error-banner">{t('bundle.ipa.failed')}: {ipaError}</div> : null}

      {/* Uploaded-IPA report. */}
      {ipa ? (
        <>
          <div class="ipa-banner">
            <span class="chip-sm">IPA</span>
            <b>{ipa.fileName}</b>
            <span class="muted">{formatBytes(ipa.fileSize)}</span>
            <span class="muted mono">{ipa.appPath}</span>
          </div>
          {ipa.warnings.length ? (
            <div class="panel-note" title={ipa.warnings.join('\n')}>
              <span class="panel-note-ic" aria-hidden="true">ⓘ</span>
              <span>{ipa.warnings.join(' · ')}</span>
            </div>
          ) : null}
          <div class="bundle-grid">
            <SummaryCard summary={ipa.summary} />
            <MachoCard macho={ipa.macho} />
            <SecurityCard security={ipa.security} />
            <PrivacyCard privacy={ipa.privacy} />
          </div>
        </>
      ) : null}

      {/* Live device bundle (hidden while an IPA report is showing). */}
      {!ipa ? (
        <>
          {error ? <div class="error-banner">{error}</div> : null}
          {loading && !summary ? <Loading labelKey="bundle.loading" /> : null}

          {summary && summary.supported !== false ? (
            <div class="bundle-grid">
              <SummaryCard summary={summary} />
              <MachoCard macho={macho} />
              <SecurityCard security={security} />

              {/* Provisioning (device-only — richer than the IPA entitlements peek). */}
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

              <PrivacyCard privacy={privacy} />
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
        </>
      ) : null}
    </div>
  );
}
