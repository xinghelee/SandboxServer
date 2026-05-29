import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import { socket } from '../api/ws';
import type { LogEntry, WsServerMessage } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';
import { formatClock } from '../util/format';

const MAX_ROWS = 2000;
const LEVELS = ['', 'debug', 'info', 'warn', 'error'] as const;
const SOURCES = ['', 'sdk', 'app', 'stdout', 'stderr'] as const;

function levelClass(level: string): string {
  return level === 'debug' || level === 'info' || level === 'warn' || level === 'error' ? level : 'info';
}

/**
 * Live console/log tail. Initial buffer comes from GET /logs (newest-first, reversed to
 * oldest-first for a terminal-style read); subsequent lines stream over the `logs` WS channel
 * and append at the bottom. Level filtering is server-side (refetch on change) and also applied
 * to live lines; the text box filters the loaded buffer client-side.
 */
export function LogsPanel() {
  const { t } = useI18n();
  const [rows, setRows] = useState<LogEntry[]>([]); // oldest-first
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [level, setLevel] = useState<string>('');
  const [source, setSource] = useState<string>('');
  const [filter, setFilter] = useState('');
  const [follow, setFollow] = useState(true);

  const scrollRef = useRef<HTMLDivElement>(null);
  const levelRef = useRef(level);
  levelRef.current = level;
  const followRef = useRef(follow);
  followRef.current = follow;

  const load = useCallback((signal?: AbortSignal) => {
    setLoading(true);
    setError(null);
    api
      .logs({ level: levelRef.current || undefined, limit: 1000 }, signal)
      .then((res) => {
        const loaded = [...res.items].reverse(); // server newest-first → oldest-first
        const lvl = levelRef.current;
        setRows((prev) => {
          if (!loaded.length) return prev.filter((r) => !lvl || r.level === lvl);
          const maxLoaded = loaded[loaded.length - 1].seq;
          // Keep live lines that arrived during the in-flight GET (seq beyond the snapshot) and
          // match the current level, so neither the initial race nor a level-change loses them.
          const tail = prev.filter((r) => r.seq > maxLoaded && (!lvl || r.level === lvl));
          const merged = [...loaded, ...tail];
          return merged.length > MAX_ROWS ? merged.slice(merged.length - MAX_ROWS) : merged;
        });
      })
      .catch((e: unknown) => {
        if (signal?.aborted) return;
        setError(e instanceof ApiRequestError ? e.message : String(e));
      })
      .finally(() => {
        if (!signal?.aborted) setLoading(false);
      });
  }, []);

  useEffect(() => {
    const ctrl = new AbortController();
    load(ctrl.signal);
    return () => ctrl.abort();
  }, [load, level]);

  useEffect(() => {
    const unsub = socket.subscribe('logs', (msg: WsServerMessage) => {
      if (msg.type !== 'log.appended') return;
      const e = msg.payload as unknown as LogEntry;
      if (levelRef.current && e.level !== levelRef.current) return;
      setRows((prev) => {
        if (prev.length && prev[prev.length - 1].seq >= e.seq) return prev; // dedupe / ordered
        const next = [...prev, e];
        return next.length > MAX_ROWS ? next.slice(next.length - MAX_ROWS) : next;
      });
    });
    return unsub;
  }, []);

  // Autoscroll to the newest line while following. Depends on `filter`/`source`/`follow` too, so
  // clearing the text filter or widening the source filter (either grows the rendered list) — or
  // re-enabling follow — re-pins to the bottom.
  useEffect(() => {
    if (followRef.current && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [rows, filter, source, follow]);

  const onClear = useCallback(() => {
    api
      .clearLogs()
      .then(() => setRows([]))
      .catch((e: unknown) => setError(e instanceof ApiRequestError ? e.message : String(e)));
  }, []);

  // Source filtering is client-side (the /logs route has no source param), applied to both the
  // loaded buffer and live lines without a refetch, so switching source never drops buffered rows.
  const f = filter.trim().toLowerCase();
  const visible = rows.filter((r) => {
    if (source && r.source !== source) return false;
    if (f && !r.message.toLowerCase().includes(f) && !r.source.toLowerCase().includes(f)) return false;
    return true;
  });

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('logs.title')}</h2>
        <span class="count-chip">{t('logs.count', { n: visible.length })}</span>
        <div class="seg-toggle level-seg">
          {LEVELS.map((l) => (
            <button
              key={l || 'all'}
              type="button"
              aria-pressed={level === l}
              class={level === l ? `on lvl-${l || 'all'}` : ''}
              onClick={() => setLevel(l)}
            >
              {t(`logs.level.${l || 'all'}`)}
            </button>
          ))}
        </div>
        <select
          class="input src-select"
          value={source}
          title={t('logs.source')}
          onChange={(e) => setSource((e.target as HTMLSelectElement).value)}
        >
          {SOURCES.map((s) => (
            <option key={s || 'all'} value={s}>
              {s ? t(`logs.src.${s}`) : t('logs.src.all')}
            </option>
          ))}
        </select>
        <div class="spacer" />
        <input
          class="input"
          type="search"
          placeholder={t('logs.filter')}
          value={filter}
          onInput={(e) => setFilter((e.target as HTMLInputElement).value)}
        />
        <button class={`btn ${follow ? 'primary' : ''}`} onClick={() => setFollow((v) => !v)}>
          {t('logs.follow')}
        </button>
        <button class="btn danger" onClick={onClear}>
          {t('logs.clear')}
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {loading && rows.length === 0 ? (
        <Loading labelKey="logs.loading" />
      ) : visible.length === 0 ? (
        <EmptyState icon="❯" titleKey="logs.empty.title" subKey="logs.empty.sub" />
      ) : (
        <div class="log-stream" ref={scrollRef}>
          {visible.map((e) => (
            <div key={e.seq} class={`log-line lvl-${levelClass(e.level)}`}>
              <span class="log-time">{formatClock(e.ts)}</span>
              <span class={`log-badge lvl-${levelClass(e.level)}`}>{e.level}</span>
              <span class="log-src">{e.source}</span>
              <span class="log-msg">{e.message}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
