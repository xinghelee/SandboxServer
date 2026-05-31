import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { NetRequestDetail } from '../api/types';
import { useI18n } from '../i18n';
import { useFocusTrap } from '../hooks/useFocusTrap';
import { Loading } from '../components/Spinner';
import { CopyButton } from '../components/CopyButton';
import { isJsonText, JsonSyntax } from '../components/JsonSyntax';
import { formatBytes, formatDuration, formatClock, prettyBody, statusClassNum } from '../util/format';
import { toCurl, toHar, harFilename } from '../util/net-export';
import { downloadText } from '../util/clipboard';
import { utf8ToBase64 } from '../util/base64';

interface Props {
  id: string;
  onClose: () => void;
  /** Open another captured request by id (used by "view new" after a replay creates one). */
  onOpen?: (id: string) => void;
}

function headersToText(headers?: Record<string, string>): string {
  return headers ? Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join('\n') : '';
}

/** Parse a "Name: value" block back into a header map (first colon splits; blank/invalid lines skipped). */
function parseHeaders(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split('\n')) {
    const i = line.indexOf(':');
    if (i <= 0) continue;
    const k = line.slice(0, i).trim();
    if (k) out[k] = line.slice(i + 1).trim();
  }
  return out;
}

/** Body whose preview the device truncated — editing it would resend only the shown slice. */
function isTruncated(body?: string | null): boolean {
  return !!body && /\(truncated, \d+ bytes total\)/.test(body);
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
  return <pre class="body">{isJsonText(pretty) ? <JsonSyntax text={pretty} /> : pretty}</pre>;
}

export function NetDetailDrawer({ id, onClose, onOpen }: Props) {
  const { t } = useI18n();
  const [detail, setDetail] = useState<NetRequestDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [showHarHelp, setShowHarHelp] = useState(false);
  const dialogRef = useRef<HTMLElement>(null);

  // Replay editor state.
  const [replayOpen, setReplayOpen] = useState(false);
  const [methodText, setMethodText] = useState('');
  const [urlText, setUrlText] = useState('');
  const [headersText, setHeadersText] = useState('');
  const [bodyText, setBodyText] = useState('');
  const [replaying, setReplaying] = useState(false);
  const [replayResult, setReplayResult] = useState<{ id: string; status: number | null; durationMs: number | null } | null>(null);
  const [replayError, setReplayError] = useState<string | null>(null);

  // Trap focus inside the drawer while open and restore it to the opening row on close; Escape closes.
  useFocusTrap(dialogRef, { onEscape: onClose });

  useEffect(() => {
    const ctrl = new AbortController();
    setLoading(true);
    setError(null);
    setDetail(null);
    // Reset the replay editor whenever we switch requests (incl. an in-flight `replaying` flag, so
    // a new request never opens with the Send/Reset buttons stuck disabled).
    setReplayOpen(false);
    setReplaying(false);
    setReplayResult(null);
    setReplayError(null);
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

  // Prefill the editor fields from the loaded detail (raw, so an untouched field round-trips exactly
  // and is therefore NOT sent — the device then keeps the original unredacted header / full body).
  const fillFromDetail = useCallback(() => {
    setMethodText(detail?.method ?? '');
    setUrlText(detail?.url ?? '');
    setHeadersText(headersToText(detail?.reqHeaders));
    setBodyText(detail?.reqBody ?? '');
  }, [detail]);

  const toggleReplay = useCallback(() => {
    setReplayOpen((open) => {
      if (!open) {
        fillFromDetail();
        setReplayError(null);
      }
      return !open;
    });
  }, [fillFromDetail]);

  const sendReplay = useCallback(() => {
    if (!detail) return;
    // Only send headers the user actually changed/added; unchanged lines (incl. "<redacted>") are
    // omitted so the device's merge keeps their real captured value. Body is sent only when edited.
    // Compare case-insensitively (HTTP header names are) so merely re-casing a name (e.g. leaving a
    // redacted "Authorization" as "authorization") isn't seen as a change — which would otherwise
    // send the literal "<redacted>" and clobber the real auth. The user's typed key casing is kept.
    const original = detail.reqHeaders ?? {};
    const originalByLower: Record<string, string> = {};
    for (const [k, v] of Object.entries(original)) originalByLower[k.toLowerCase()] = v;
    const edited = parseHeaders(headersText);
    const headerOverrides: Record<string, string> = {};
    for (const [k, v] of Object.entries(edited)) {
      if (originalByLower[k.toLowerCase()] !== v) headerOverrides[k] = v;
    }
    const overrides: { method?: string; url?: string; headers?: Record<string, string>; body?: string } = {};
    const method = methodText.trim().toUpperCase();
    if (method && method !== detail.method.toUpperCase()) overrides.method = method;
    const url = urlText.trim();
    if (url && url !== detail.url) overrides.url = url;
    if (Object.keys(headerOverrides).length > 0) overrides.headers = headerOverrides;
    if (bodyText !== (detail.reqBody ?? '')) overrides.body = utf8ToBase64(bodyText);

    setReplaying(true);
    setReplayError(null);
    setReplayResult(null);
    api
      .netReplay(id, overrides)
      .then((d) => setReplayResult({ id: d.id, status: d.status, durationMs: d.durationMs }))
      .catch((e: unknown) => setReplayError(e instanceof ApiRequestError ? e.message : String(e)))
      .finally(() => setReplaying(false));
  }, [detail, methodText, urlText, headersText, bodyText, id]);

  return (
    <>
      <div class="drawer-scrim" onClick={onClose} aria-hidden="true" />
      <aside
        class="drawer"
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label={`${detail?.method ?? ''} ${detail?.url ?? id}`.trim()}
        tabIndex={-1}
      >
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
                <button
                  type="button"
                  class={`copy-btn ${replayOpen ? 'on' : ''}`}
                  aria-pressed={replayOpen}
                  onClick={toggleReplay}
                >
                  {t('d.replay')}
                </button>
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

              {replayOpen ? (
                <div class="replay-editor">
                  <div class="replay-line">
                    <label class="replay-inline">
                      <span>{t('d.replay.method')}</span>
                      <input
                        class="input replay-method"
                        value={methodText}
                        spellcheck={false}
                        onInput={(e) => setMethodText((e.target as HTMLInputElement).value)}
                      />
                    </label>
                    <label class="replay-inline replay-url-field">
                      <span>{t('d.replay.url')}</span>
                      <input
                        class="input replay-url"
                        value={urlText}
                        spellcheck={false}
                        onInput={(e) => setUrlText((e.target as HTMLInputElement).value)}
                      />
                    </label>
                  </div>
                  <div class="help-note">{t('d.replay.note')}</div>

                  <label class="replay-label" for="replay-headers">{t('d.replay.headers')}</label>
                  <textarea
                    id="replay-headers"
                    class="replay-ta"
                    rows={5}
                    spellcheck={false}
                    placeholder={t('d.replay.headers.placeholder')}
                    value={headersText}
                    onInput={(e) => setHeadersText((e.target as HTMLTextAreaElement).value)}
                  />

                  <label class="replay-label" for="replay-body">{t('d.replay.body')}</label>
                  {isTruncated(detail.reqBody) ? <div class="replay-warn">{t('d.replay.truncNote')}</div> : null}
                  <textarea
                    id="replay-body"
                    class="replay-ta mono"
                    rows={6}
                    spellcheck={false}
                    placeholder={t('d.replay.body.placeholder')}
                    value={bodyText}
                    onInput={(e) => setBodyText((e.target as HTMLTextAreaElement).value)}
                  />

                  <div class="replay-row">
                    <button type="button" class="btn primary" disabled={replaying} onClick={sendReplay}>
                      {replaying ? t('d.replay.sending') : t('d.replay.send')}
                    </button>
                    <button type="button" class="btn" disabled={replaying} onClick={fillFromDetail}>
                      {t('d.replay.reset')}
                    </button>
                  </div>

                  {replayError ? <div class="error-banner">{t('d.replay.failed')}: {replayError}</div> : null}
                  {replayResult ? (
                    <div class="replay-result">
                      <span class="replay-ok">{t('d.replay.ok')}</span>
                      <span class={`status ${statusClassNum(replayResult.status)}`}>{replayResult.status ?? '—'}</span>
                      <span class="muted">{formatDuration(replayResult.durationMs)}</span>
                      {onOpen ? (
                        <button type="button" class="copy-btn" onClick={() => onOpen(replayResult.id)}>
                          {t('d.replay.view')}
                        </button>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              ) : null}

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
