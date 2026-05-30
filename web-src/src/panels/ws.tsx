import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import { socket } from '../api/ws';
import type {
  WsConnSummary,
  WsMsgSummary,
  WsServerMessage,
  WsOpenedPayload,
  WsClosedPayload,
} from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';
import { formatBytes, formatClock } from '../util/format';

function cleanWsReason(raw: string) {
  const localized = raw.match(/NSLocalizedDescription=([^,}]+)/)?.[1];
  if (localized) return localized.trim();
  const quoted = raw.match(/"([^"]+)"/)?.[1];
  return (quoted || raw).trim();
}

function wsProblem(conn: Pick<WsConnSummary, 'error' | 'closeReason'>) {
  if (conn.error) return { labelKey: 'ws.failure', text: cleanWsReason(conn.error), title: conn.error };
  if (conn.closeReason) return { labelKey: 'ws.closeReason', text: cleanWsReason(conn.closeReason), title: conn.closeReason };
  return null;
}

/** Captured WebSocket connections (URLSessionWebSocketTask). List → per-connection message stream. */
export function WSPanel() {
  const { t } = useI18n();
  const [conns, setConns] = useState<WsConnSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);

  const load = useCallback((signal?: AbortSignal) => {
    setLoading(true);
    setError(null);
    api
      .wsConnections(signal)
      .then((r) => setConns(r.items))
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

  // Keep the connection list fresh from the live `ws` channel.
  useEffect(
    () =>
      socket.subscribe('ws', (msg: WsServerMessage) => {
        if (msg.type === 'connection.opened') {
          const p = msg.payload as unknown as WsOpenedPayload;
          setConns((prev) =>
            prev.some((c) => c.id === p.id)
              ? prev
              : [
                  { id: p.id, url: p.url, host: p.host, startedAt: p.startedAt, state: 'open', closedAt: null, messageCount: 0 },
                  ...prev,
                ],
          );
        } else if (msg.type === 'connection.closed') {
          const p = msg.payload as unknown as WsClosedPayload;
          setConns((prev) =>
            prev.map((c) =>
              c.id === p.id
                ? { ...c, state: p.state, closedAt: p.closedAt, closeReason: p.closeReason ?? null, error: p.error ?? null }
                : c,
            ),
          );
        } else if (msg.type === 'message') {
          const p = msg.payload as unknown as WsMsgSummary;
          setConns((prev) => prev.map((c) => (c.id === p.connId ? { ...c, messageCount: c.messageCount + 1 } : c)));
        }
      }),
    [],
  );

  const onClear = useCallback(() => {
    api
      .clearWsConnections()
      .then(() => {
        setConns([]);
        setSelected(null);
      })
      .catch((e: unknown) => setError(e instanceof ApiRequestError ? e.message : String(e)));
  }, []);

  const conn = selected ? conns.find((c) => c.id === selected) ?? null : null;
  if (conn) return <WSConnectionView conn={conn} onBack={() => setSelected(null)} />;

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('ws.title')}</h2>
        {!loading ? <span class="count-chip">{t('ws.count', { n: conns.length })}</span> : null}
        <div class="spacer" />
        <button class="btn" onClick={() => load()}>
          {t('net.refresh')}
        </button>
        <button class="btn danger" onClick={onClear}>
          {t('net.clear')}
        </button>
      </div>

      <div class="panel-note">
        <span class="panel-note-ic" aria-hidden="true">ⓘ</span>
        <span>{t('ws.note')}</span>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {loading && conns.length === 0 ? (
        <Loading labelKey="ws.loading" />
      ) : conns.length === 0 ? (
        <EmptyState icon="⇅" titleKey="ws.empty.title" subKey="ws.empty.sub" />
      ) : (
        <div class="db-list">
          {conns.map((c) => {
            const problem = wsProblem(c);
            return (
              <button class="db-card as-button" key={c.id} onClick={() => setSelected(c.id)}>
                <span class={`ws-state ${c.state}`}>{c.state}</span>
                <div class="ws-conn-main">
                  <div class="db-name" title={c.url}>
                    {c.url}
                  </div>
                  <div class="db-path">{c.host}</div>
                  {problem ? (
                    <div class="ws-reason" title={problem.title}>
                      <span>{t(problem.labelKey)}:</span> {problem.text}
                    </div>
                  ) : null}
                </div>
                <span class="count-chip">{t('ws.msgs', { n: c.messageCount })}</span>
                <span class="db-go">›</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

function WSConnectionView({ conn, onBack }: { conn: WsConnSummary; onBack: () => void }) {
  const { t } = useI18n();
  const [msgs, setMsgs] = useState<WsMsgSummary[]>([]);
  const [error, setError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const problem = wsProblem(conn);

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .wsMessages(conn.id, ctrl.signal)
      .then((r) => setMsgs(r.items))
      .catch((e: unknown) => {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      });
    return () => ctrl.abort();
  }, [conn.id]);

  useEffect(
    () =>
      socket.subscribe('ws', (msg: WsServerMessage) => {
        if (msg.type !== 'message') return;
        const p = msg.payload as unknown as WsMsgSummary;
        if (p.connId !== conn.id) return;
        setMsgs((prev) => (prev.some((m) => m.id === p.id) ? prev : [...prev, p]));
      }),
    [conn.id],
  );

  // Follow the tail as new frames arrive.
  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [msgs]);

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <button class="btn" onClick={onBack}>
          ‹ {t('ws.back')}
        </button>
        <span class={`ws-state ${conn.state}`}>{conn.state}</span>
        <h2 style="font-size:15px; min-width:0; overflow:hidden; text-overflow:ellipsis" title={conn.url}>
          {conn.url}
        </h2>
        <div class="spacer" />
        <span class="count-chip">{t('ws.msgs', { n: msgs.length })}</span>
      </div>

      {problem ? (
        <div class="ws-detail-reason" title={problem.title}>
          <span>{t(problem.labelKey)}:</span> {problem.text}
        </div>
      ) : null}

      {error ? <div class="error-banner">{error}</div> : null}

      {msgs.length === 0 ? (
        <EmptyState icon="⇅" titleKey="ws.msg.empty.title" subKey="ws.msg.empty.sub" />
      ) : (
        <div class="log-stream ws-stream" ref={scrollRef}>
          {msgs.map((m) => (
            <div key={m.id} class={`ws-msg ${m.direction}`}>
              <span class="ws-dir">{m.direction === 'sent' ? '↑' : '↓'}</span>
              <span class="log-time">{formatClock(m.ts)}</span>
              <span class="log-badge">{m.opcode}</span>
              <span class="ws-size">{formatBytes(m.size)}</span>
              <span class="log-msg">{m.preview ?? ''}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
