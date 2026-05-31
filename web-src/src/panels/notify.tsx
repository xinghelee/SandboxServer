import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DeliveredNotification, NotifySettings, PendingNotification } from '../api/types';
import { useI18n } from '../i18n';

const CARD =
  'border:1px solid rgba(128,128,128,0.22);border-radius:10px;padding:14px;' +
  'background:rgba(128,128,128,0.04);display:flex;flex-direction:column;gap:10px;min-width:0';
const FIELD =
  'font-size:13px;padding:6px 9px;border:1px solid rgba(128,128,128,0.3);border-radius:6px;background:rgba(128,128,128,0.05);color:inherit;width:100%;box-sizing:border-box';
const BTN =
  'font-size:12px;padding:5px 12px;border-radius:6px;border:1px solid var(--accent);background:var(--accent);color:#000;cursor:pointer';
const BTN_GHOST =
  'font-size:11px;padding:4px 10px;border-radius:6px;border:1px solid rgba(128,128,128,0.3);background:transparent;color:inherit;cursor:pointer';

function statusTone(s: string): string {
  if (s === 'authorized' || s === 'enabled' || s === 'provisional' || s === 'ephemeral') return '#3fb950';
  if (s === 'denied' || s === 'disabled') return '#f85149';
  return 'var(--ink-dim)';
}

function Chip({ label, value }: { label: string; value: string }) {
  return (
    <span style={`font-size:11px;border:1px solid rgba(128,128,128,0.3);border-radius:6px;padding:2px 8px;color:${statusTone(value)}`}>
      {label}: {value}
    </span>
  );
}

/** Notification tester — inspect/request authorization, fire local notifications, simulate a push. */
export function NotifyPanel() {
  const { t } = useI18n();
  const [settings, setSettings] = useState<NotifySettings | null>(null);
  const [pending, setPending] = useState<PendingNotification[]>([]);
  const [delivered, setDelivered] = useState<DeliveredNotification[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  // local-notification form
  const [title, setTitle] = useState('SandboxServer');
  const [body, setBody] = useState('Hello from the console');
  const [delay, setDelay] = useState('0');
  const [badge, setBadge] = useState('');
  const [sound, setSound] = useState(true);

  // remote-push form
  const [payload, setPayload] = useState('{\n  "aps": { "alert": "Test push", "badge": 1, "sound": "default" }\n}');

  const refresh = async () => {
    setError(null);
    try {
      const [s, p, d] = await Promise.all([api.notifySettings(), api.notifyPending(), api.notifyDelivered()]);
      setSettings(s);
      setPending(p.items);
      setDelivered(d.items);
    } catch (e: unknown) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    }
  };

  useEffect(() => {
    refresh();
  }, []);

  const flash = (msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 2500);
  };
  const guard = async (fn: () => Promise<void>) => {
    setError(null);
    try {
      await fn();
    } catch (e: unknown) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    }
  };

  const requestAuth = () =>
    guard(async () => {
      const r = await api.notifyRequestAuth();
      flash(t('notify.auth.result', { state: r.granted ? t('notify.auth.granted') : t('notify.auth.notgranted'), status: r.status }));
      await refresh();
    });

  const sendLocal = () =>
    guard(async () => {
      const r = await api.notifySendLocal({
        title: title || undefined,
        body: body || undefined,
        delay: Number(delay) || 0,
        badge: badge === '' ? undefined : Number(badge),
        sound,
      });
      flash(t('notify.local.sent', { id: r.id, delay: r.scheduledInSeconds }));
      await refresh();
    });

  const simulateRemote = () =>
    guard(async () => {
      let parsed: Record<string, unknown>;
      try {
        parsed = JSON.parse(payload) as Record<string, unknown>;
      } catch {
        setError(t('notify.remote.badjson'));
        return;
      }
      const r = await api.notifySimulateRemote(parsed);
      flash(r.delivered ? t('notify.remote.ok') : t('notify.remote.none'));
    });

  const clear = (scope: 'pending' | 'delivered' | 'all') =>
    guard(async () => {
      await api.notifyClear(scope);
      await refresh();
    });

  const unsupported = settings ? !settings.supported : false;

  return (
    <div class="panel">
      <div class="panel-toolbar" style="flex-wrap:wrap;gap:8px">
        <h2>{t('notify.title')}</h2>
        {unsupported ? <span class="count-chip" style="color:#d29922">{t('act.unsupported')}</span> : null}
        <div class="spacer" />
        <button onClick={refresh} style={BTN_GHOST}>{t('act.refresh')}</button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}
      {toast ? <div class="error-banner" style="border-color:rgba(63,185,80,0.5);color:#3fb950">{toast}</div> : null}

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px;padding:12px">
        {/* Authorization + settings */}
        <div style={CARD}>
          <div style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7">{t('notify.auth')}</div>
          {settings ? (
            <div style="display:flex;flex-wrap:wrap;gap:6px">
              <Chip label="status" value={settings.authorizationStatus} />
              <Chip label="alert" value={settings.alert} />
              <Chip label="sound" value={settings.sound} />
              <Chip label="badge" value={settings.badge} />
              <Chip label="lock" value={settings.lockScreen} />
            </div>
          ) : (
            <div style="opacity:0.6">{t('act.loading')}</div>
          )}
          <div>
            <button onClick={requestAuth} disabled={unsupported} style={BTN}>{t('notify.auth.request')}</button>
          </div>
        </div>

        {/* Local notification */}
        <div style={CARD}>
          <div style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7">{t('notify.local')}</div>
          <input placeholder={t('notify.local.title')} value={title} onInput={(e) => setTitle((e.target as HTMLInputElement).value)} style={FIELD} />
          <input placeholder={t('notify.local.body')} value={body} onInput={(e) => setBody((e.target as HTMLInputElement).value)} style={FIELD} />
          <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
            <label style="font-size:12px;opacity:0.7">{t('notify.local.delay')}</label>
            <input value={delay} onInput={(e) => setDelay((e.target as HTMLInputElement).value)} style={`${FIELD};width:64px`} />
            <label style="font-size:12px;opacity:0.7">{t('notify.local.badge')}</label>
            <input value={badge} placeholder="—" onInput={(e) => setBadge((e.target as HTMLInputElement).value)} style={`${FIELD};width:64px`} />
            <label style="font-size:12px;opacity:0.7;display:flex;align-items:center;gap:4px">
              <input type="checkbox" checked={sound} onChange={(e) => setSound((e.target as HTMLInputElement).checked)} />
              {t('notify.local.sound')}
            </label>
          </div>
          <div>
            <button onClick={sendLocal} disabled={unsupported} style={BTN}>{t('act.send')}</button>
          </div>
        </div>

        {/* Simulate remote push */}
        <div style={CARD}>
          <div style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7">{t('notify.remote')}</div>
          <textarea
            value={payload}
            spellcheck={false}
            onInput={(e) => setPayload((e.target as HTMLTextAreaElement).value)}
            style={`${FIELD};font-family:var(--mono,monospace);min-height:96px;resize:vertical`}
          />
          <div style="font-size:11px;opacity:0.55">{t('notify.remote.note')}</div>
          <div>
            <button onClick={simulateRemote} disabled={unsupported} style={BTN}>{t('notify.remote.send')}</button>
          </div>
        </div>
      </div>

      {/* Pending + delivered */}
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px;padding:0 12px 12px">
        <div style={CARD}>
          <div style="display:flex;align-items:center;gap:8px">
            <div style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7">{t('notify.pending')}</div>
            <span class="count-chip">{pending.length}</span>
            <div class="spacer" style="flex:1" />
            <button onClick={() => clear('pending')} style={BTN_GHOST}>{t('act.clear')}</button>
          </div>
          {pending.length === 0 ? (
            <div style="opacity:0.6;font-size:13px">{t('notify.pending.empty')}</div>
          ) : (
            pending.map((n) => (
              <div key={n.id} style="font-size:12px;border-bottom:1px solid rgba(128,128,128,0.12);padding:5px 0">
                <b>{n.title || t('notify.notitle')}</b>{' '}
                {n.triggerSeconds != null
                  ? `· ${t('notify.pending.in', { s: n.triggerSeconds })}${n.repeats ? t('notify.pending.repeats') : ''}`
                  : ''}
                <div style="opacity:0.7">{n.body}</div>
              </div>
            ))
          )}
        </div>

        <div style={CARD}>
          <div style="display:flex;align-items:center;gap:8px">
            <div style="font-size:11px;letter-spacing:0.08em;text-transform:uppercase;opacity:0.7">{t('notify.delivered')}</div>
            <span class="count-chip">{delivered.length}</span>
            <div class="spacer" style="flex:1" />
            <button onClick={() => clear('delivered')} style={BTN_GHOST}>{t('act.clear')}</button>
          </div>
          {delivered.length === 0 ? (
            <div style="opacity:0.6;font-size:13px">{t('notify.delivered.empty')}</div>
          ) : (
            delivered.map((n) => (
              <div key={n.id} style="font-size:12px;border-bottom:1px solid rgba(128,128,128,0.12);padding:5px 0">
                <b>{n.title || t('notify.notitle')}</b>
                <div style="opacity:0.7">{n.body}</div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}
