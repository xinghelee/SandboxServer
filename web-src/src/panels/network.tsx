import { useEffect, useMemo, useRef, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import { socket } from '../api/ws';
import type {
  NetRequestSummary,
  Plugin,
  WsServerMessage,
  NetStartedPayload,
  NetCompletedPayload,
} from '../api/types';
import { useI18n } from '../i18n';
import { useVirtualWindow } from '../hooks/useVirtualWindow';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';
import { NetDetailDrawer } from './NetDetailDrawer';
import { FilterBuilder } from '../components/FilterBuilder';
import { formatBytes, formatDuration, formatClock, shortUrl, statusClassNum } from '../util/format';
import { parseNetQuery, matchesNetQuery, hasQuery } from '../util/net-filter';

const MAX_ROWS = 1000;
const STATUS_CLASSES = ['', 's2', 's3', 's4', 's5'] as const;
const CLASS_LABEL: Record<string, string> = { s2: '2xx', s3: '3xx', s4: '4xx', s5: '5xx' };
const METHOD_ORDER = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];

// Filter state survives reloads (it's used constantly while debugging a single flow).
const FILTER_KEY = 'sbx.net.filter';
interface PersistedFilter {
  q: string;
  statusClass: string;
  method: string;
}
function loadFilter(): PersistedFilter {
  const empty: PersistedFilter = { q: '', statusClass: '', method: '' };
  try {
    return { ...empty, ...(JSON.parse(sessionStorage.getItem(FILTER_KEY) || '{}') as Partial<PersistedFilter>) };
  } catch {
    return empty;
  }
}

export function NetworkPanel(_props: { plugin?: Plugin }) {
  const { t } = useI18n();
  const [rows, setRows] = useState<NetRequestSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const persisted = useMemo(loadFilter, []);
  const [filter, setFilter] = useState(persisted.q);
  const [statusClass, setStatusClass] = useState(persisted.statusClass);
  const [method, setMethod] = useState(persisted.method);
  const [showHelp, setShowHelp] = useState(false);
  const [showBuilder, setShowBuilder] = useState(false);

  const rowsRef = useRef<NetRequestSummary[]>([]);
  rowsRef.current = rows;

  const scrollRef = useRef<HTMLDivElement>(null);
  const [rowH, setRowH] = useState(39); // measured from the first rendered row (see below)

  const load = useCallback((signal?: AbortSignal) => {
    setLoading(true);
    setError(null);
    api
      .netRequests({ limit: 200 }, signal)
      .then((res) => setRows(res.items))
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
  }, [load]);

  useEffect(() => {
    const unsub = socket.subscribe('net', (msg: WsServerMessage) => {
      if (msg.type === 'request.started') {
        const p = msg.payload as unknown as NetStartedPayload;
        setRows((prev) => {
          if (prev.some((r) => r.id === p.id)) return prev;
          const next: NetRequestSummary = {
            id: p.id,
            method: p.method,
            url: p.url,
            status: null,
            startedAt: p.startedAt,
            durationMs: null,
            reqBytes: null,
            respBytes: null,
          };
          return [next, ...prev].slice(0, MAX_ROWS);
        });
      } else if (msg.type === 'request.completed') {
        const p = msg.payload as unknown as NetCompletedPayload;
        setRows((prev) => {
          let found = false;
          const patched = prev.map((r) => {
            if (r.id !== p.id) return r;
            found = true;
            return {
              ...r,
              status: p.status,
              durationMs: p.durationMs,
              reqBytes: p.reqBytes,
              respBytes: p.respBytes,
              url: p.url ?? r.url,
              method: p.method ?? r.method,
            };
          });
          if (found) return patched;
          const row: NetRequestSummary = {
            id: p.id,
            method: p.method,
            url: p.url,
            status: p.status,
            startedAt: p.startedAt,
            durationMs: p.durationMs,
            reqBytes: p.reqBytes,
            respBytes: p.respBytes,
          };
          return [row, ...prev].slice(0, MAX_ROWS);
        });
      }
    });
    return unsub;
  }, []);

  const onClear = useCallback(() => {
    api
      .clearNetRequests()
      .then(() => {
        setRows([]);
        setSelected(null);
      })
      .catch((e: unknown) => setError(e instanceof ApiRequestError ? e.message : String(e)));
  }, []);

  // Persist the active filter so a reload (frequent while debugging) keeps it.
  useEffect(() => {
    try {
      sessionStorage.setItem(FILTER_KEY, JSON.stringify({ q: filter, statusClass, method }));
    } catch {
      /* private mode / quota — non-fatal */
    }
  }, [filter, statusClass, method]);

  // Method chips reflect the methods actually present, in a canonical order.
  const presentMethods = useMemo(() => {
    const set = new Set(rows.map((r) => (r.method || '').toUpperCase()).filter(Boolean));
    return Array.from(set).sort(
      (a, b) => (METHOD_ORDER.indexOf(a) + 1 || 99) - (METHOD_ORDER.indexOf(b) + 1 || 99),
    );
  }, [rows]);

  const query = useMemo(() => parseNetQuery(filter), [filter]);
  const visible = rows.filter((r) => {
    // Status-class filter excludes still-pending rows (statusClassNum(null) === 'pending').
    if (statusClass && statusClassNum(r.status) !== statusClass) return false;
    if (method && (r.method || '').toUpperCase() !== method) return false;
    return matchesNetQuery(r, query);
  });
  const filtered = !!statusClass || !!method || hasQuery(query);
  const clearFilters = () => {
    setFilter('');
    setStatusClass('');
    setMethod('');
  };

  const win = useVirtualWindow(scrollRef, { count: visible.length, rowHeight: rowH, enabled: visible.length > 0 });
  const windowed = visible.slice(win.start, win.end);

  // Pin the windowing row height to the real rendered height so the spacer math can't drift.
  useEffect(() => {
    const tr = scrollRef.current?.querySelector('tbody tr.v-row') as HTMLElement | null;
    const h = tr?.getBoundingClientRect().height;
    if (h && Math.abs(h - rowH) > 0.5) setRowH(h);
  }, [visible.length > 0, rowH]);

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('net.title')}</h2>
        <span class="count-chip">
          {filtered ? t('net.count.of', { n: visible.length, total: rows.length }) : t('net.count', { n: rows.length })}
        </span>
        <div class="seg-toggle status-seg">
          {STATUS_CLASSES.map((c) => (
            <button
              key={c || 'all'}
              type="button"
              aria-pressed={statusClass === c}
              class={statusClass === c ? `on ${c || 'all'}` : ''}
              onClick={() => setStatusClass(c)}
            >
              {c ? CLASS_LABEL[c] : t('net.status.all')}
            </button>
          ))}
        </div>
        {presentMethods.length > 0 ? (
          <div class="seg-toggle method-seg">
            <button type="button" aria-pressed={!method} class={!method ? 'on' : ''} onClick={() => setMethod('')}>
              {t('net.method.all')}
            </button>
            {presentMethods.map((m) => (
              <button key={m} type="button" aria-pressed={method === m} class={method === m ? 'on' : ''} onClick={() => setMethod(m)}>
                {m}
              </button>
            ))}
          </div>
        ) : null}
        <div class="spacer" />
        <input
          class="input"
          type="search"
          placeholder={t('net.filter')}
          title={t('net.filter.hint')}
          value={filter}
          onInput={(e) => setFilter((e.target as HTMLInputElement).value)}
        />
        <button
          type="button"
          class={`btn ${showBuilder ? 'primary' : ''}`}
          aria-pressed={showBuilder}
          onClick={() => setShowBuilder((v) => !v)}
        >
          {t('fb.toggle')}
        </button>
        <button
          type="button"
          class={`help-dot ${showHelp ? 'on' : ''}`}
          aria-expanded={showHelp}
          title={t('net.filter.hint')}
          aria-label={t('net.filter.hint')}
          onClick={() => setShowHelp((v) => !v)}
        >
          ?
        </button>
        {filtered ? (
          <button type="button" class="btn" onClick={clearFilters} title={t('net.filter.clear')}>
            {t('net.filter.clear')}
          </button>
        ) : null}
        <button class="btn" onClick={() => load()}>
          {t('net.refresh')}
        </button>
        <button class="btn danger" onClick={onClear}>
          {t('net.clear')}
        </button>
      </div>

      {showHelp ? <div class="help-note">{t('net.filter.hint')}</div> : null}
      {showBuilder ? <FilterBuilder filter={filter} setFilter={setFilter} /> : null}

      {error ? <div class="error-banner">{error}</div> : null}

      {loading && rows.length === 0 ? (
        <Loading labelKey="net.loading" />
      ) : visible.length === 0 ? (
        <EmptyState icon="↯" titleKey="net.empty.title" subKey="net.empty.sub" />
      ) : (
        <div class="table-wrap" ref={scrollRef}>
          <table class="grid v-grid">
            <thead>
              <tr>
                <th style="width:74px">{t('net.col.method')}</th>
                <th>{t('net.col.url')}</th>
                <th style="width:84px">{t('net.col.status')}</th>
                <th style="width:84px" class="col-num">
                  {t('net.col.dur')}
                </th>
                <th style="width:78px" class="col-num">
                  {t('net.col.size')}
                </th>
                <th style="width:118px">{t('net.col.clock')}</th>
              </tr>
            </thead>
            <tbody>
              {win.padTop > 0 ? (
                <tr class="v-pad" aria-hidden="true">
                  <td colSpan={6} style={`height:${win.padTop}px`} />
                </tr>
              ) : null}
              {windowed.map((r) => (
                <tr
                  key={r.id}
                  class={`v-row ${selected === r.id ? 'selected' : ''} ${r.status === null ? 'pending' : ''}`}
                  data-method={r.method?.toUpperCase()}
                  role="button"
                  tabIndex={0}
                  aria-label={`${r.method} ${r.url}`}
                  onClick={() => setSelected(r.id)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault();
                      setSelected(r.id);
                    }
                  }}
                >
                  <td class="col-method">{r.method}</td>
                  <td class="col-url" title={r.url}>
                    {shortUrl(r.url)}
                  </td>
                  <td>
                    <span class={`status ${statusClassNum(r.status)}`}>{r.status ?? '···'}</span>
                  </td>
                  <td class="col-num">{formatDuration(r.durationMs)}</td>
                  <td class="col-num">{formatBytes(r.respBytes)}</td>
                  <td class="col-time">{formatClock(r.startedAt)}</td>
                </tr>
              ))}
              {win.padBottom > 0 ? (
                <tr class="v-pad" aria-hidden="true">
                  <td colSpan={6} style={`height:${win.padBottom}px`} />
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      )}

      {selected ? (
        <NetDetailDrawer id={selected} onClose={() => setSelected(null)} onOpen={setSelected} />
      ) : null}
    </div>
  );
}
