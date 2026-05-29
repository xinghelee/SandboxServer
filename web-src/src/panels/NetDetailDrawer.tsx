import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { NetRequestDetail } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { formatBytes, formatDuration, formatClock, prettyBody, statusClassNum } from '../util/format';

interface Props {
  id: string;
  onClose: () => void;
}

function Headers({ headers, empty }: { headers?: Record<string, string>; empty: string }) {
  const entries = headers ? Object.entries(headers) : [];
  if (entries.length === 0) return <div class="muted">{empty}</div>;
  return (
    <table class="headers">
      <tbody>
        {entries.map(([k, v]) => (
          <tr key={k}>
            <td class="hk">{k}</td>
            <td class="hv">{v}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function Body({ body, empty }: { body?: string | null; empty: string }) {
  const pretty = prettyBody(body);
  if (!pretty) return <div class="muted">{empty}</div>;
  return <pre class="body">{pretty}</pre>;
}

export function NetDetailDrawer({ id, onClose }: Props) {
  const { t } = useI18n();
  const [detail, setDetail] = useState<NetRequestDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const ctrl = new AbortController();
    setLoading(true);
    setError(null);
    setDetail(null);
    api
      .netRequestDetail(id, ctrl.signal)
      .then((d) => setDetail(d))
      .catch((e: unknown) => {
        if (ctrl.signal.aborted) return;
        setError(e instanceof ApiRequestError ? e.message : String(e));
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoading(false);
      });
    return () => ctrl.abort();
  }, [id]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <>
      <div class="drawer-scrim" onClick={onClose} />
      <aside class="drawer">
        <div class="drawer-head">
          <span class="d-method">{detail?.method ?? '…'}</span>
          <span class="d-url" title={detail?.url}>
            {detail?.url ?? id}
          </span>
          <button class="x" onClick={onClose} aria-label={t('d.close')}>
            ×
          </button>
        </div>
        <div class="drawer-body">
          {loading ? <Loading labelKey="d.loading" /> : null}
          {error ? <div class="error-banner">{error}</div> : null}
          {detail ? (
            <>
              <div class="kv">
                <div class="kv-item">
                  <div class="k">{t('d.status')}</div>
                  <div class={`v status ${statusClassNum(detail.status)}`}>{detail.status ?? '—'}</div>
                </div>
                <div class="kv-item">
                  <div class="k">{t('d.duration')}</div>
                  <div class="v">{formatDuration(detail.durationMs)}</div>
                </div>
                <div class="kv-item">
                  <div class="k">{t('d.started')}</div>
                  <div class="v">{formatClock(detail.startedAt)}</div>
                </div>
                <div class="kv-item">
                  <div class="k">{t('d.reqsize')}</div>
                  <div class="v">{formatBytes(detail.reqBytes)}</div>
                </div>
                <div class="kv-item">
                  <div class="k">{t('d.respsize')}</div>
                  <div class="v">{formatBytes(detail.respBytes)}</div>
                </div>
              </div>

              <div class="section-title">{t('d.reqheaders')}</div>
              <Headers headers={detail.reqHeaders} empty={t('d.noheaders')} />

              <div class="section-title">{t('d.reqbody')}</div>
              <Body body={detail.reqBody} empty={t('d.emptybody')} />

              <div class="section-title">{t('d.respheaders')}</div>
              <Headers headers={detail.respHeaders} empty={t('d.noheaders')} />

              <div class="section-title">{t('d.respbody')}</div>
              <Body body={detail.respBody} empty={t('d.emptybody')} />
            </>
          ) : null}
        </div>
      </aside>
    </>
  );
}
