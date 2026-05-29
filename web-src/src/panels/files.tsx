import { useEffect, useState } from 'preact/hooks';
import { request, ApiRequestError } from '../api/client';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';

type Probe = 'loading' | 'not-implemented' | { error: string };

export function FilesPanel() {
  const { t } = useI18n();
  const [probe, setProbe] = useState<Probe>('loading');

  useEffect(() => {
    const ctrl = new AbortController();
    request('/fs/list', { query: { path: '/' }, signal: ctrl.signal })
      .then(() => {
        if (!ctrl.signal.aborted) setProbe('not-implemented');
      })
      .catch((e: unknown) => {
        if (ctrl.signal.aborted) return;
        if (e instanceof ApiRequestError && e.isNotImplemented) setProbe('not-implemented');
        else if (e instanceof ApiRequestError) setProbe({ error: e.message });
        else setProbe({ error: String(e) });
      });
    return () => ctrl.abort();
  }, []);

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('fs.title')}</h2>
        <div class="spacer" />
      </div>
      {probe === 'loading' ? (
        <Loading labelKey="fs.loading" />
      ) : probe === 'not-implemented' ? (
        <EmptyState icon="◰" titleKey="fs.notimpl.title" subKey="fs.notimpl.sub" tag="GET /fs/list → 501" />
      ) : (
        <div class="error-banner">{probe.error}</div>
      )}
    </div>
  );
}
