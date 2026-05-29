import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { NetRequestDetail } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { CopyButton } from '../components/CopyButton';
import { formatBytes, formatDuration, formatClock, prettyBody, statusClassNum } from '../util/format';
import { toCurl, toHar, harFilename } from '../util/net-export';
import { downloadText } from '../util/clipboard';

interface Props {
  id: string;
  onClose: () => void;
}

function headersToText(headers?: Record<string, string>): string {
  return headers ? Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join('\n') : '';
}

function SectionTitle({ label, copy }: { label: string; copy?: string | null }) {
  return (
    <div class="section-row">
      <span class="section-title">{label}</span>
      {copy ? <CopyButton text={copy} /> : null}
    </div>
  );
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
  const [showHarHelp, setShowHarHelp] = useState(false);

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

              <div class="drawer-actions">
                <CopyButton text={detail.url} label={t('d.copyUrl')} />
                <CopyButton text={() => toCurl(detail)} label={t('d.curl')} />
                <button
                  type="button"
                  class="copy-btn"
                  onClick={() => downloadText(harFilename(detail), toHar(detail), 'application/json')}
                >
                  {t('d.har')}
                </button>
                <button
                  type="button"
                  class={`help-dot ${showHarHelp ? 'on' : ''}`}
                  aria-expanded={showHarHelp}
                  title={t('d.har.helpTitle')}
                  aria-label={t('d.har.helpTitle')}
                  onClick={() => setShowHarHelp((v) => !v)}
                >
                  ?
                </button>
              </div>
              {showHarHelp ? <div class="help-note">{t('d.har.help')}</div> : null}

              <SectionTitle label={t('d.reqheaders')} copy={headersToText(detail.reqHeaders) || null} />
              <Headers headers={detail.reqHeaders} empty={t('d.noheaders')} />

              <SectionTitle label={t('d.reqbody')} copy={prettyBody(detail.reqBody) || null} />
              <Body body={detail.reqBody} empty={t('d.emptybody')} />

              <SectionTitle label={t('d.respheaders')} copy={headersToText(detail.respHeaders) || null} />
              <Headers headers={detail.respHeaders} empty={t('d.noheaders')} />

              <SectionTitle label={t('d.respbody')} copy={prettyBody(detail.respBody) || null} />
              <Body body={detail.respBody} empty={t('d.emptybody')} />
            </>
          ) : null}
        </div>
      </aside>
    </>
  );
}
