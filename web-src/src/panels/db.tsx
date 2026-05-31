import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DbDescriptor, DbTable, DbSchema, DbQueryResult, DbCell, DbBlobCell } from '../api/types';
import { useI18n } from '../i18n';
import { useVirtualWindow } from '../hooks/useVirtualWindow';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';
import { CopyButton } from '../components/CopyButton';
import { JsonSyntax } from '../components/JsonSyntax';
import { navigate } from '../router';
import { formatBytes } from '../util/format';
import { isBinaryPlist, parseBinaryPlist } from '../util/ipa/bplist';

const DB_MAX_ROWS = 5000; // cap on accumulated loadMore rows so the grid can't grow unbounded
type DbViewMode = 'list' | 'grid';
const DB_VIEW_KEY = 'sbx.db.view';
type BlobSelection = { column: string; rowNumber: number; cell: DbBlobCell };
type RowSelection = { rowNumber: number; columns: string[]; row: DbCell[] };
type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
type DecodedPreview = { label: string; text: string; tree?: JsonValue };

function loadDbViewMode(): DbViewMode {
  try {
    return localStorage.getItem(DB_VIEW_KEY) === 'grid' ? 'grid' : 'list';
  } catch {
    return 'list';
  }
}

function requestedDbPath() {
  const query = window.location.hash.split('?')[1] || '';
  return new URLSearchParams(query).get('path');
}

function isBlobCell(cell: DbCell): cell is DbBlobCell {
  return !!cell && typeof cell === 'object' && (cell as DbBlobCell).kind === 'blob';
}

export function DbPanel() {
  const { t } = useI18n();
  const targetPath = requestedDbPath();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [dbs, setDbs] = useState<DbDescriptor[]>([]);
  const [selected, setSelected] = useState<DbDescriptor | null>(null);
  const [viewMode, setViewMode] = useState<DbViewMode>(loadDbViewMode);

  const setView = (mode: DbViewMode) => {
    setViewMode(mode);
    try {
      localStorage.setItem(DB_VIEW_KEY, mode);
    } catch {
      /* storage is optional */
    }
  };

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

  useEffect(() => {
    if (!targetPath || selected || dbs.length === 0) return;
    const match = dbs.find((db) => db.path === targetPath || db.id === targetPath);
    if (match) setSelected(match);
  }, [dbs, selected, targetPath]);

  const backToList = () => {
    setSelected(null);
    if (targetPath) navigate('/db');
  };

  if (selected) return <DbExplorer db={selected} onBack={backToList} />;

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('db.title')}</h2>
        {!loading && dbs.length > 0 ? <span class="count-chip">{t('db.found', { n: dbs.length })}</span> : null}
        <div class="spacer" />
        {!loading && dbs.length > 0 ? (
          <div class="seg-toggle db-view-toggle" title={t('db.view')}>
            <button type="button" class={viewMode === 'list' ? 'on' : ''} aria-pressed={viewMode === 'list'} onClick={() => setView('list')}>
              ▤ {t('db.view.list')}
            </button>
            <button type="button" class={viewMode === 'grid' ? 'on' : ''} aria-pressed={viewMode === 'grid'} onClick={() => setView('grid')}>
              ▦ {t('db.view.grid')}
            </button>
          </div>
        ) : null}
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {loading ? (
        <Loading labelKey="db.loading" />
      ) : dbs.length === 0 ? (
        <EmptyState icon="▤" titleKey="db.empty.title" subKey="db.empty.sub" />
      ) : (
        <div class={`db-list ${viewMode}`}>
          {dbs.map((db) => (
            <button class={`db-card as-button ${viewMode} db-${db.engine}`} key={db.id} onClick={() => setSelected(db)}>
              {viewMode === 'grid' ? (
                <span class={`db-card-visual ${db.engine}`} aria-hidden="true">
                  <span>{db.engine === 'sqlite' ? 'SQL' : db.engine === 'coredata' ? 'CD' : 'RM'}</span>
                </span>
              ) : null}
              <span class={`engine-badge ${db.engine}`}>{db.engine}</span>
              <div class="db-card-main">
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
  const [blob, setBlob] = useState<BlobSelection | null>(null);
  const [rowDetail, setRowDetail] = useState<RowSelection | null>(null);
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
      setBlob(null);
      setRowDetail(null);
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
    setBlob(null);
    setRowDetail(null);
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
      {blob ? <BlobPreview selection={blob} onClose={() => setBlob(null)} /> : null}

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
                {result.rows.slice(win.start, win.end).map((row, i) => {
                  const rowNumber = win.start + i + 1;
                  const selectedRow = rowDetail?.rowNumber === rowNumber;
                  return (
                    <tr
                      key={win.start + i}
                      class={`v-row ${selectedRow ? 'selected' : ''}`}
                      role="button"
                      tabIndex={0}
                      aria-label={t('db.row.number', { n: rowNumber })}
                      onClick={() => {
                        setBlob(null);
                        setRowDetail({ rowNumber, columns: result.columns, row });
                      }}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault();
                          setBlob(null);
                          setRowDetail({ rowNumber, columns: result.columns, row });
                        }
                      }}
                    >
                      {row.map((cell, j) => (
                        <td key={j}>{renderCell(cell, result.columns[j] ?? String(j + 1), rowNumber, setBlob)}</td>
                      ))}
                    </tr>
                  );
                })}
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

      {rowDetail ? <RowDetailPanel selection={rowDetail} onClose={() => setRowDetail(null)} /> : null}
    </div>
  );
}

function renderCell(
  cell: DbCell,
  column: string,
  rowNumber: number,
  onBlob: (selection: BlobSelection) => void,
) {
  if (cell === null) return <span class="cell-null">NULL</span>;
  if (isBlobCell(cell)) {
    return (
      <button
        class="db-blob-cell"
        type="button"
        onClick={(e) => {
          e.stopPropagation();
          onBlob({ column, rowNumber, cell });
        }}
      >
        <span class="db-blob-kind">BLOB</span>
        <span>{formatBytes(cell.bytes)}</span>
      </button>
    );
  }
  return String(cell);
}

function RowDetailPanel({ selection, onClose }: { selection: RowSelection; onClose: () => void }) {
  const { t } = useI18n();
  const dialogRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    dialogRef.current?.focus();
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      previous?.focus?.();
    };
  }, [onClose]);

  return (
    <>
      <div class="drawer-scrim" onClick={onClose} aria-hidden="true" />
      <aside
        class="drawer db-row-drawer"
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label={`${t('db.row.preview')} ${t('db.row.number', { n: selection.rowNumber })}`}
        tabIndex={-1}
      >
        <div class="drawer-head">
          <span class="d-method">{t('db.row.number', { n: selection.rowNumber })}</span>
          <span class="d-url">{t('db.row.preview')}</span>
          <button class="x" onClick={onClose} aria-label={t('d.close')}>
            ×
          </button>
        </div>
        <div class="drawer-body db-row-drawer-body">
          <div class="db-row-grid">
            {selection.columns.map((column, index) => (
              <RowField
                key={`${column || index}-${index}`}
                column={column || String(index + 1)}
                cell={selection.row[index] ?? null}
              />
            ))}
          </div>
        </div>
      </aside>
    </>
  );
}

function RowField({ column, cell }: { column: string; cell: DbCell }) {
  const { t } = useI18n();
  if (cell === null) {
    return (
      <div class="db-row-field">
        <div class="db-row-col">{column}</div>
        <div class="cell-null">NULL</div>
      </div>
    );
  }

  if (isBlobCell(cell)) {
    const preview = decodeBlob(cell);
    return (
      <div class="db-row-field blob">
        <div class="db-row-field-head">
          <div class="db-row-col">{column}</div>
          <div class="muted">
            BLOB · {formatBytes(cell.bytes)}
            {cell.truncated ? ` · ${t('db.blob.truncated', { n: formatBytes(cell.previewBytes) })}` : ''}
          </div>
        </div>
        <ValuePreview preview={preview} />
      </div>
    );
  }

  const preview = decodeScalar(cell);
  return (
    <div class="db-row-field">
      <div class="db-row-col">{column}</div>
      <ValuePreview preview={{ ...preview, label: preview.label || t('db.row.value') }} scalar />
    </div>
  );
}

function BlobPreview({ selection, onClose }: { selection: BlobSelection; onClose: () => void }) {
  const { t } = useI18n();
  const preview = decodeBlob(selection.cell);
  return (
    <section class="db-blob-preview">
      <div class="db-blob-head">
        <div>
          <div class="section-title">{t('db.blob.preview')}</div>
          <div class="muted">
            {selection.column} · {t('db.row.number', { n: selection.rowNumber })} · {formatBytes(selection.cell.bytes)}
            {selection.cell.truncated ? ` · ${t('db.blob.truncated', { n: formatBytes(selection.cell.previewBytes) })}` : ''}
          </div>
        </div>
        <button class="btn" onClick={onClose}>
          {t('d.close')}
        </button>
      </div>
      <ValuePreview preview={preview} blobPreview />
    </section>
  );
}

function ValuePreview({
  preview,
  scalar = false,
  blobPreview = false,
}: {
  preview: DecodedPreview;
  scalar?: boolean;
  blobPreview?: boolean;
}) {
  const { t } = useI18n();
  const hasTree = preview.tree !== undefined;
  const [view, setView] = useState<'tree' | 'raw'>('raw');

  useEffect(() => {
    setView('raw');
  }, [preview.text]);

  const rawClass = blobPreview ? 'body db-blob-body' : `body db-row-value ${scalar ? 'scalar' : ''}`;
  return (
    <>
      <div class="db-value-head">
        <div class="db-blob-mode">{preview.label}</div>
        <div class="db-value-actions">
          {hasTree ? (
            <div class="seg-toggle db-view-toggle">
              <button type="button" class={view === 'tree' ? 'on' : ''} aria-pressed={view === 'tree'} onClick={() => setView('tree')}>
                {t('db.view.tree')}
              </button>
              <button type="button" class={view === 'raw' ? 'on' : ''} aria-pressed={view === 'raw'} onClick={() => setView('raw')}>
                {t('db.view.raw')}
              </button>
            </div>
          ) : null}
          <CopyButton text={() => preview.text} />
        </div>
      </div>
      {hasTree && view === 'tree' ? (
        <div class={`body db-json-tree ${scalar ? 'scalar' : ''}`}>
          <JsonTree value={preview.tree as JsonValue} />
        </div>
      ) : (
        <pre class={rawClass}>{hasTree ? <JsonSyntax text={preview.text} /> : preview.text}</pre>
      )}
    </>
  );
}

function JsonTree({ value }: { value: JsonValue }) {
  return (
    <div class="json-table">
      <div class="json-table-head">
        <span>Key</span>
        <span>Value</span>
      </div>
      <JsonTreeNode name="Root" value={value} depth={0} root />
    </div>
  );
}

function JsonTreeNode({ name, value, depth, root = false }: { name: string; value: JsonValue; depth: number; root?: boolean }) {
  if (Array.isArray(value) || isJsonObject(value)) {
    const entries = Array.isArray(value) ? value.map((item, index) => [String(index), item] as const) : Object.entries(value);
    return (
      <details class={`json-node ${root ? 'root' : ''}`} open={depth < 2}>
        <summary class="json-tree-line json-node-line" style={`--json-depth:${depth}`}>
          <span class={`json-key-cell ${root ? 'root' : ''}`}>
            <span class="json-caret" aria-hidden="true">
              ›
            </span>
            {name}
          </span>
          <span class="json-value-cell json-container-value">{containerLabel(value, entries.length)}</span>
        </summary>
        <div class="json-children">
          {entries.map(([key, item]) => (
            <JsonTreeNode key={key} name={key} value={item} depth={depth + 1} />
          ))}
        </div>
      </details>
    );
  }

  return (
    <div class={`json-tree-line json-leaf ${root ? 'root' : ''}`} style={`--json-depth:${depth}`}>
      <span class={`json-key-cell ${root ? 'root' : ''}`}>
        <span class="json-caret-spacer" aria-hidden="true" />
        {name}
      </span>
      <JsonPrimitive value={value} />
    </div>
  );
}

function JsonPrimitive({ value }: { value: Exclude<JsonValue, JsonValue[] | { [key: string]: JsonValue }> }) {
  if (value === null) return <span class="json-value-cell json-tree-null">null</span>;
  if (typeof value === 'string') return <span class="json-value-cell json-tree-string">{value}</span>;
  if (typeof value === 'boolean') return <span class="json-value-cell json-tree-boolean">{String(value)}</span>;
  return <span class="json-value-cell json-tree-number">{String(value)}</span>;
}

function containerLabel(value: JsonValue[] | { [key: string]: JsonValue }, count: number) {
  const type = Array.isArray(value) ? 'Array' : 'Object';
  return `${type}(${count} ${count === 1 ? 'item' : 'items'})`;
}

function decodeScalar(cell: Exclude<DbCell, DbBlobCell | null>): DecodedPreview {
  if (typeof cell === 'string') {
    const trimmed = cell.trim();
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        const parsed = JSON.parse(trimmed) as unknown;
        return { label: 'JSON text', text: JSON.stringify(parsed, null, 2), tree: normalizeJsonValue(parsed) };
      } catch {
        return { label: 'text', text: cell };
      }
    }
    return { label: 'text', text: cell };
  }
  return { label: typeof cell, text: String(cell) };
}

function decodeBlob(cell: DbBlobCell): DecodedPreview {
  const bytes = base64ToBytes(cell.base64);
  if (!bytes.length) return { label: 'empty blob', text: '' };

  if (isBinaryPlist(bytes)) {
    try {
      const parsed = parseBinaryPlist(bytes) as unknown;
      return {
        label: 'binary plist',
        text: JSON.stringify(parsed, null, 2),
        tree: normalizeJsonValue(parsed),
      };
    } catch {
      // Fall through to hex if the plist is an NSKeyedArchiver variant outside our parser subset.
    }
  }

  const text = decodeUtf8(bytes);
  if (text != null && isReadableText(text)) {
    const trimmed = text.trim();
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        const parsed = JSON.parse(trimmed) as unknown;
        return { label: 'JSON text', text: JSON.stringify(parsed, null, 2), tree: normalizeJsonValue(parsed) };
      } catch {
        return { label: 'text', text };
      }
    }
    return { label: 'text', text };
  }

  return { label: 'hex', text: hexDump(bytes) };
}

function normalizeJsonValue(value: unknown): JsonValue {
  if (value === null) return null;
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value;
  if (Array.isArray(value)) return value.map((item) => normalizeJsonValue(item));
  if (typeof value === 'object') {
    const out: { [key: string]: JsonValue } = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      out[key] = normalizeJsonValue(item);
    }
    return out;
  }
  return String(value);
}

function isJsonObject(value: JsonValue): value is { [key: string]: JsonValue } {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function base64ToBytes(base64: string): Uint8Array {
  if (!base64) return new Uint8Array();
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function decodeUtf8(bytes: Uint8Array): string | null {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

function isReadableText(text: string): boolean {
  if (!text) return true;
  let control = 0;
  for (const ch of text) {
    const code = ch.charCodeAt(0);
    if ((code < 32 && !'\n\r\t'.includes(ch)) || code === 127) control++;
  }
  return control / text.length < 0.02;
}

function hexDump(bytes: Uint8Array): string {
  const max = Math.min(bytes.length, 4096);
  const lines: string[] = [];
  for (let offset = 0; offset < max; offset += 16) {
    const slice = bytes.subarray(offset, Math.min(offset + 16, max));
    const hex = Array.from(slice, (b) => b.toString(16).padStart(2, '0')).join(' ').padEnd(47, ' ');
    const ascii = Array.from(slice, (b) => (b >= 32 && b < 127 ? String.fromCharCode(b) : '.')).join('');
    lines.push(`${offset.toString(16).padStart(8, '0')}  ${hex}  ${ascii}`);
  }
  if (bytes.length > max) lines.push(`... ${formatBytes(bytes.length - max)} more in preview`);
  return lines.join('\n');
}
