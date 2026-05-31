import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DeepLinkInfo } from '../api/types';
import { useI18n } from '../i18n';

const CHIP =
  'font-size:12px;font-family:var(--mono,monospace);border:1px solid rgba(128,128,128,0.3);' +
  'border-radius:6px;padding:3px 9px;background:rgba(128,128,128,0.05);color:inherit;cursor:pointer';

/**
 * Deep-link / URL-scheme trigger. Lists the schemes the app declares (CFBundleURLTypes) as
 * one-tap chips, and opens any URL (custom scheme or universal/https link) in the host app.
 */
export function DeepLinkPanel() {
  const { t } = useI18n();
  const [info, setInfo] = useState<DeepLinkInfo | null>(null);
  const [url, setUrl] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ url: string; accepted: boolean } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .deepLinks(ctrl.signal)
      .then(setInfo)
      .catch((e: unknown) => {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      });
    return () => ctrl.abort();
  }, []);

  const open = async () => {
    const target = url.trim();
    if (!target) return;
    setBusy(true);
    setError(null);
    setResult(null);
    try {
      setResult(await api.deepLinkOpen(target));
    } catch (e: unknown) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('deeplink.title')}</h2>
        <div class="spacer" />
        {info && !info.supported ? <span class="count-chip" style="color:#d29922">{t('act.unsupported')}</span> : null}
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      <div style="padding:14px;display:flex;flex-direction:column;gap:14px;max-width:760px">
        <div style="display:flex;gap:8px">
          <input
            placeholder={t('deeplink.url')}
            value={url}
            spellcheck={false}
            onInput={(e) => setUrl((e.target as HTMLInputElement).value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') open();
            }}
            style="flex:1;font-family:var(--mono,monospace);font-size:13px;padding:8px 11px;border:1px solid rgba(128,128,128,0.3);border-radius:8px;background:rgba(128,128,128,0.05);color:inherit;min-width:0"
          />
          <button
            onClick={open}
            disabled={busy || !url.trim() || (info ? !info.supported : false)}
            style="font-size:13px;padding:8px 18px;border-radius:8px;border:1px solid var(--accent);background:var(--accent);color:#000;cursor:pointer"
          >
            {t('act.open')}
          </button>
        </div>

        {result ? (
          <div
            class="error-banner"
            style={`border-color:${result.accepted ? 'rgba(63,185,80,0.5)' : 'rgba(248,81,73,0.5)'};color:${result.accepted ? '#3fb950' : '#f85149'}`}
          >
            {result.accepted ? t('deeplink.accepted') : t('deeplink.rejected')}: {result.url}
          </div>
        ) : null}

        <div>
          <div style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7;margin-bottom:8px">
            {t('deeplink.schemes')}
          </div>
          {info && info.schemes.length > 0 ? (
            <div style="display:flex;flex-wrap:wrap;gap:8px">
              {info.schemes.map((s) => (
                <button key={s} style={CHIP} onClick={() => setUrl(`${s}://`)}>
                  {s}://
                </button>
              ))}
            </div>
          ) : (
            <div style="opacity:0.6;font-size:13px">{t('deeplink.schemes.none')}</div>
          )}
        </div>

        <div style="font-size:11px;opacity:0.55">{t('deeplink.note')}</div>
      </div>
    </div>
  );
}
