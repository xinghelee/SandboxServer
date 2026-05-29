import { useState } from 'preact/hooks';
import { useI18n } from '../i18n';
import {
  type BuilderField,
  type BuilderRow,
  blankRow,
  compileBuilder,
  rowsFromQuery,
} from '../util/net-filter';

const FIELDS: BuilderField[] = ['any', 'method', 'status', 'host', 'url', 'dur', 'size'];
const OPS: Record<BuilderField, string[]> = {
  any: ['contains'],
  method: ['is'],
  status: ['is', '>=', '<=', '>', '<'],
  host: ['contains'],
  url: ['contains', 'matches'],
  dur: ['>', '<', '>=', '<='],
  size: ['>', '<', '>=', '<='],
};

/** A visual editor that compiles to the net-filter query string (the single source of truth). */
export function FilterBuilder({ filter, setFilter }: { filter: string; setFilter: (q: string) => void }) {
  const { t } = useI18n();
  // Seed from the current filter when possible; never clobber on open (only edits write back).
  const [rows, setRows] = useState<BuilderRow[]>(() => rowsFromQuery(filter) ?? [blankRow()]);
  const [matchAny, setMatchAny] = useState(false);

  const apply = (nextRows: BuilderRow[], nextAny: boolean) => {
    setRows(nextRows);
    setMatchAny(nextAny);
    setFilter(compileBuilder(nextRows, nextAny));
  };
  const update = (i: number, patch: Partial<BuilderRow>) =>
    apply(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)), matchAny);
  const opLabel = (op: string) =>
    op === 'contains' || op === 'is' || op === 'matches' ? t(`fb.op.${op}`) : op;

  return (
    <div class="filter-builder">
      <div class="fb-head">
        <div class="seg-toggle">
          <button type="button" class={!matchAny ? 'on' : ''} onClick={() => apply(rows, false)}>
            {t('fb.all')}
          </button>
          <button type="button" class={matchAny ? 'on' : ''} onClick={() => apply(rows, true)}>
            {t('fb.any')}
          </button>
        </div>
        <div class="spacer" />
        <button type="button" class="btn" onClick={() => apply([...rows, blankRow()], matchAny)}>
          + {t('fb.add')}
        </button>
      </div>

      {rows.map((r, i) => (
        <div class="fb-row" key={i}>
          <select
            class="input"
            value={r.field}
            onChange={(e) => {
              const field = (e.target as HTMLSelectElement).value as BuilderField;
              update(i, { field, op: OPS[field][0] ?? 'contains' });
            }}
          >
            {FIELDS.map((f) => (
              <option key={f} value={f}>
                {t(`fb.field.${f}`)}
              </option>
            ))}
          </select>

          <select
            class="input fb-op"
            value={r.op}
            onChange={(e) => update(i, { op: (e.target as HTMLSelectElement).value })}
          >
            {(OPS[r.field] ?? ['contains']).map((op) => (
              <option key={op} value={op}>
                {opLabel(op)}
              </option>
            ))}
          </select>

          <input
            class="input fb-val"
            type="text"
            spellcheck={false}
            value={r.value}
            placeholder={t('fb.value')}
            onInput={(e) => update(i, { value: (e.target as HTMLInputElement).value })}
          />

          <button
            type="button"
            class={`fb-not ${r.negate ? 'on' : ''}`}
            title={t('fb.not')}
            aria-pressed={r.negate}
            onClick={() => update(i, { negate: !r.negate })}
          >
            {t('fb.not')}
          </button>
          <button
            type="button"
            class="fb-del"
            title={t('fb.remove')}
            aria-label={t('fb.remove')}
            onClick={() => apply(rows.length > 1 ? rows.filter((_, j) => j !== i) : [blankRow()], matchAny)}
          >
            ×
          </button>
        </div>
      ))}
    </div>
  );
}
