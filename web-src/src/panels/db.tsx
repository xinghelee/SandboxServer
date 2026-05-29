import { useEffect, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DbDescriptor, DbTable, DbSchema, DbQueryResult, DbCell } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';

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

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .dbTables(db.id, ctrl.signal)
      .then((res) => {
        if (ctrl.signal.aborted) return;
        setTables(res.items);
        if (res.items[0]) openTable(res.items[0].name);
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

  const loadMore = useCallback(() => {
    if (!result?.nextCursor || !table) return;
    setBusy(true);
    api
      .dbQuery(db.id, { table, limit: 100, cursor: result.nextCursor })
      .then((res) => setResult((prev) => (prev ? { ...res, rows: [...prev.rows, ...res.rows] } : res)))
      .catch((e: unknown) => setError(e instanceof ApiRequestError ? e.message : String(e)))
      .finally(() => setBusy(false));
  }, [db.id, table, result]);

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
              <span class="ct">{tb.rowCount >= 0 ? tb.rowCount : '?'}</span>
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
          <div class="table-wrap">
            <table class="grid">
              <thead>
                <tr>
                  {result.columns.map((c) => (
                    <th key={c}>{c}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {result.rows.map((row, i) => (
                  <tr key={i}>
                    {row.map((cell, j) => (
                      <td key={j}>{renderCell(cell)}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {result.nextCursor && table ? (
            <div style="margin-top:12px">
              <button class="btn" onClick={loadMore} disabled={busy}>
                {t('db.loadmore')}
              </button>
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
