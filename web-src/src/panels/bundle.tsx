import { useCallback, useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { BundleSummary } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { FileBrowser } from './FileBrowser';

export function BundlePanel() {
  const { t } = useI18n();
  const [summary, setSummary] = useState<BundleSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

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
  }, []);

  useEffect(() => {
    const ctrl = new AbortController();
    load(ctrl.signal);
    return () => ctrl.abort();
  }, [load]);

  return (
    <div class="panel bundle-panel">
      <div class="panel-toolbar">
        <h2>{t('bundle.title')}</h2>
        <div class="spacer" />
        <button class="btn" onClick={() => load()}>
          {t('bundle.reload')}
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}
      {loading && !summary ? <Loading labelKey="bundle.loading" /> : null}

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
