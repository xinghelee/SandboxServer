import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DbDescriptor, DbTable, DbSchema, DbQueryResult, DbCell } from '../api/types';
import { useI18n } from '../i18n';
import { useVirtualWindow } from '../hooks/useVirtualWindow';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';

const DB_MAX_ROWS = 5000; // cap on accumulated loadMore rows so the grid can't grow unbounded

export function DbPanel() {
  const { t } = useI18n();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [dbs, setDbs] = useState<DbDescriptor[]>([]);
  const [selected, setSelected] = useState<DbDescriptor | null>(null);

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .databases(ctrl.signal)
      .then((res) => {
        if (!ctrl.signal.aborted) setDbs(res.items);
      })
      .catch((e: unknown) => {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoading(false);
      });
    return () => ctrl.abort();
  }, []);

  if (selected) return <DbExplorer db={selected} onBack={() => setSelected(null)} />;

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('db.title')}</h2>
        {!loading && dbs.length > 0 ? <span class="count-chip">{t('db.found', { n: dbs.length })}</span> : null}
        <div class="spacer" />
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {loading ? (
        <Loading labelKey="db.loading" />
      ) : dbs.length === 0 ? (
        <EmptyState icon="▤" titleKey="db.empty.title" subKey="db.empty.sub" />
      ) : (
        <div class="db-list">
          {dbs.map((db) => (
            <button class="db-card as-button" key={db.id} onClick={() => setSelected(db)}>
              <span class={`engine-badge ${db.engine}`}>{db.engine}</span>
              <div style="flex:1; min-width:0; text-align:left">
                <div class="db-name">{db.name}</div>
                <div class="db-path" title={db.path}>
                  {db.path}
                </div>
              </div>
              {db.readOnly ? <span class="ro-badge">{t('db.readonly')}</span> : null}
              <span class="db-go">›</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function DbExplorer({ db, onBack }: { db: DbDescriptor; onBack: () => void }) {
  const { t } = useI18n();
  const [tables, setTables] = useState<DbTable[]>([]);
  const [table, setTable] = useState<string | null>(null);
  const [schema, setSchema] = useState<DbSchema | null>(null);
  const [result, setResult] = useState<DbQueryResult | null>(null);
  const [sql, setSql] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [rowH, setRowH] = useState(38);

  useEffect(() => {
    const ctrl = new AbortController();
    // Fetch the table list without row counts first — that's instant even on huge DBs. Then load
    // counts in the background (a per-table COUNT(*) full scan) and merge them in so the chips fill
    // without ever blocking the panel.
    api
      .dbTables(db.id, ctrl.signal)
      .then((res) => {
        if (ctrl.signal.aborted) return;
        setTables(res.items);
        if (res.items[0]) openTable(res.items[0].name);
        return api.dbTables(db.id, ctrl.signal, { counts: true });
      })
      .then((counted) => {
        if (!counted || ctrl.signal.aborted) return;
        const byName = new Map(counted.items.map((tb) => [tb.name, tb.rowCount]));
        setTables((prev) => prev.map((tb) => ({ ...tb, rowCount: byName.get(tb.name) ?? tb.rowCount })));
      })
      .catch((e: unknown) => {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      });
    return () => ctrl.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [db.id]);

  const openTable = useCallback(
    (name: string) => {
      setTable(name);
      setError(null);
      setBusy(true);
      setSql('');
      Promise.all([api.dbQuery(db.id, { table: name, limit: 100 }), api.dbSchema(db.id, name)])
        .then(([res, sch]) => {
          setResult(res);
          setSchema(sch);
        })
        .catch((e: unknown) => setError(e instanceof ApiRequestError ? e.message : String(e)))
        .finally(() => setBusy(false));
    },
    [db.id],
  );

  const runSql = useCallback(() => {
    if (!sql.trim()) return;
    setTable(null);
    setSchema(null);
    setError(null);
    setBusy(true);
    api
      .dbQuery(db.id, { sql, limit: 200 })
      .then(setResult)
      .catch((e: unknown) => setError(e instanceof ApiRequestError ? e.message : String(e)))
      .finally(() => setBusy(false));
  }, [db.id, sql]);

  const atRowCap = (result?.rows.length ?? 0) >= DB_MAX_ROWS;
  const loadMore = useCallback(() => {
    if (!result?.nextCursor || !table || (result?.rows.length ?? 0) >= DB_MAX_ROWS) return;
    setBusy(true);
    api
      .dbQuery(db.id, { table, limit: 100, cursor: result.nextCursor })
      .then((res) => setResult((prev) => (prev ? { ...res, rows: [...prev.rows, ...res.rows] } : res)))
      .catch((e: unknown) => setError(e instanceof ApiRequestError ? e.message : String(e)))
      .finally(() => setBusy(false));
  }, [db.id, table, result]);

  const rowCount = result?.rows.length ?? 0;
  const win = useVirtualWindow(scrollRef, { count: rowCount, rowHeight: rowH, enabled: rowCount > 0 });
  useEffect(() => {
    const tr = scrollRef.current?.querySelector('tbody tr.v-row') as HTMLElement | null;
    const h = tr?.getBoundingClientRect().height;
    if (h && Math.abs(h - rowH) > 0.5) setRowH(h);
  }, [rowCount > 0, rowH]);

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <button class="btn" onClick={onBack}>
          ‹ {t('db.back')}
        </button>
        <h2 style="font-size:16px">{db.name}</h2>
        <span class="ro-badge">{t('db.readonlyNote')}</span>
        <div class="spacer" />
      </div>

      {tables.length > 0 ? (
        <div class="db-tablechips">
          {tables.map((tb) => (
            <button
              key={tb.name}
              class={`db-tablechip ${table === tb.name ? 'on' : ''}`}
              onClick={() => openTable(tb.name)}
            >
              {tb.name}
              <span class="ct">{tb.rowCount != null && tb.rowCount >= 0 ? tb.rowCount : '—'}</span>
            </button>
          ))}
        </div>
      ) : null}

      <div class="db-sqlbox">
        <textarea
          class="fs-editor sql"
          placeholder={t('db.sql.ph')}
          value={sql}
          spellcheck={false}
          onInput={(e) => setSql((e.target as HTMLTextAreaElement).value)}
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') runSql();
          }}
        />
        <button class="btn primary" onClick={runSql} disabled={busy || !sql.trim()}>
          {t('db.run')} ⌘↵
        </button>
      </div>

      {schema ? (
        <div class="db-schema">
          <span class="muted">{t('db.schema')}:</span>
          {schema.columns.map((c) => (
            <span class="col-pill" key={c.name}>
              {c.name} <span class="ty">{c.type || '—'}</span>
              {c.pk ? <span class="flag pk">{t('db.pk')}</span> : null}
              {c.notnull ? <span class="flag nn">{t('db.notnull')}</span> : null}
            </span>
          ))}
        </div>
      ) : null}

      {error ? <div class="error-banner">{error}</div> : null}

      {busy && !result ? (
        <Loading labelKey="db.loading" />
      ) : result ? (
        <>
          <div class="table-wrap" ref={scrollRef}>
            <table class="grid v-grid">
              <thead>
                <tr>
                  {result.columns.map((c) => (
                    <th key={c}>{c}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {win.padTop > 0 ? (
                  <tr class="v-pad" aria-hidden="true">
                    <td colSpan={result.columns.length} style={`height:${win.padTop}px`} />
                  </tr>
                ) : null}
                {result.rows.slice(win.start, win.end).map((row, i) => (
                  <tr key={win.start + i} class="v-row">
                    {row.map((cell, j) => (
                      <td key={j}>{renderCell(cell)}</td>
                    ))}
                  </tr>
                ))}
                {win.padBottom > 0 ? (
                  <tr class="v-pad" aria-hidden="true">
                    <td colSpan={result.columns.length} style={`height:${win.padBottom}px`} />
                  </tr>
                ) : null}
              </tbody>
            </table>
          </div>
          {result.nextCursor && table && !atRowCap ? (
            <div style="margin-top:12px">
              <button class="btn" onClick={loadMore} disabled={busy}>
                {t('db.loadmore')}
              </button>
            </div>
          ) : atRowCap ? (
            <div class="muted" style="margin-top:12px">
              {t('db.rowcap', { n: DB_MAX_ROWS })}
            </div>
          ) : null}
        </>
      ) : null}
    </div>
  );
}

function renderCell(cell: DbCell) {
  if (cell === null) return <span class="cell-null">NULL</span>;
  return String(cell);
}
