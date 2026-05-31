import { useEffect, useMemo, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DefaultsEntry, DefaultsListing } from '../api/types';

const CHIP =
  'font-size:10px;letter-spacing:0.04em;text-transform:uppercase;opacity:0.7;' +
  'border:1px solid rgba(128,128,128,0.3);border-radius:5px;padding:1px 5px;white-space:nowrap';

/** Parse an edit-field string back into a JSON value, falling back to a plain string. */
function parseValue(raw: string): unknown {
  const t = raw.trim();
  if (t === '') return '';
  try {
    return JSON.parse(t);
  } catch {
    return raw;
  }
}

/** How a stored value is shown in the (editable) value field — JSON so it round-trips precisely. */
function toEditString(value: unknown): string {
  if (typeof value === 'string') return JSON.stringify(value);
  return JSON.stringify(value ?? null);
}

function Row({
  entry,
  onSave,
  onDelete,
}: {
  entry: DefaultsEntry;
  onSave: (key: string, value: unknown) => Promise<void>;
  onDelete: (key: string) => Promise<void>;
}) {
  const original = toEditString(entry.value);
  const [draft, setDraft] = useState(original);
  const [busy, setBusy] = useState(false);
  const dirty = draft !== original;

  useEffect(() => setDraft(toEditString(entry.value)), [entry.key, entry.preview]);

  return (
    <div style="display:grid;grid-template-columns:minmax(140px,1fr) auto minmax(160px,1.6fr) auto;gap:10px;align-items:center;padding:7px 12px;border-bottom:1px solid rgba(128,128,128,0.12)">
      <code style="font-size:12px;word-break:break-all">{entry.key}</code>
      <span style={CHIP}>{entry.type}</span>
      <input
        value={draft}
        spellcheck={false}
        onInput={(e) => setDraft((e.target as HTMLInputElement).value)}
        style="font-family:var(--mono,monospace);font-size:12px;padding:4px 7px;border:1px solid rgba(128,128,128,0.3);border-radius:6px;background:rgba(128,128,128,0.05);color:inherit;min-width:0"
      />
      <div style="display:flex;gap:6px;justify-content:flex-end">
        <button
          disabled={!dirty || busy}
          onClick={async () => {
            setBusy(true);
            try {
              await onSave(entry.key, parseValue(draft));
            } finally {
              setBusy(false);
            }
          }}
          style={`font-size:11px;padding:3px 9px;border-radius:6px;border:1px solid var(--accent);background:${dirty ? 'var(--accent)' : 'transparent'};color:${dirty ? '#000' : 'var(--ink-dim)'};cursor:${dirty ? 'pointer' : 'default'}`}
        >
          save
        </button>
        <button
          disabled={busy}
          title="delete key"
          onClick={async () => {
            setBusy(true);
            try {
              await onDelete(entry.key);
            } finally {
              setBusy(false);
            }
          }}
          style="font-size:13px;line-height:1;padding:3px 8px;border-radius:6px;border:1px solid rgba(248,81,73,0.5);background:transparent;color:#f85149;cursor:pointer"
        >
          ×
        </button>
      </div>
    </div>
  );
}

/**
 * UserDefaults inspector + editor. Lists the app's persisted defaults (scope=app) or the full
 * resolved dictionary (scope=all), filtered by an optional prefix and suite (App Group / custom
 * suite name). Values are edited as JSON so types round-trip; null saves remove the key.
 */
export function DefaultsPanel() {
  const [suite, setSuite] = useState('');
  const [scope, setScope] = useState<'app' | 'all'>('app');
  const [prefix, setPrefix] = useState('');
  const [listing, setListing] = useState<DefaultsListing | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [newKey, setNewKey] = useState('');
  const [newValue, setNewValue] = useState('');

  const load = useMemo(
    () => async (signal?: AbortSignal) => {
      setLoading(true);
      setError(null);
      try {
        const res = await api.defaultsList({ suite: suite || undefined, scope, prefix: prefix || undefined }, signal);
        setListing(res);
      } catch (e: unknown) {
        if (!(signal?.aborted)) setError(e instanceof ApiRequestError ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    },
    [suite, scope, prefix],
  );

  useEffect(() => {
    const ctrl = new AbortController();
    load(ctrl.signal);
    return () => ctrl.abort();
  }, [load]);

  const onSave = async (key: string, value: unknown) => {
    try {
      await api.defaultsSet(key, value, { suite: suite || undefined });
      await load();
    } catch (e: unknown) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    }
  };
  const onDelete = async (key: string) => {
    try {
      await api.defaultsDelete(key, suite || undefined);
      await load();
    } catch (e: unknown) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    }
  };
  const onAdd = async () => {
    if (!newKey.trim()) return;
    await onSave(newKey.trim(), parseValue(newValue || '""'));
    setNewKey('');
    setNewValue('');
  };
  const onReset = async () => {
    const domain = suite || listing?.suite || 'this app';
    if (!confirm(`Reset (delete ALL keys in) the "${domain}" defaults domain? This cannot be undone.`)) return;
    try {
      await api.defaultsReset(suite || undefined);
      await load();
    } catch (e: unknown) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    }
  };

  const items = listing?.items ?? [];

  return (
    <div class="panel">
      <div class="panel-toolbar" style="flex-wrap:wrap;gap:8px">
        <h2>Defaults</h2>
        {listing ? <span class="count-chip">{listing.count}</span> : null}
        <div class="spacer" />
        <input
          placeholder="suite (App Group)…"
          value={suite}
          onInput={(e) => setSuite((e.target as HTMLInputElement).value)}
          onChange={() => load()}
          style="font-size:12px;padding:4px 8px;border:1px solid rgba(128,128,128,0.3);border-radius:6px;background:transparent;color:inherit;width:150px"
        />
        <input
          placeholder="prefix filter…"
          value={prefix}
          onInput={(e) => setPrefix((e.target as HTMLInputElement).value)}
          style="font-size:12px;padding:4px 8px;border:1px solid rgba(128,128,128,0.3);border-radius:6px;background:transparent;color:inherit;width:130px"
        />
        <button
          onClick={() => setScope((s) => (s === 'app' ? 'all' : 'app'))}
          title="app = this app's own keys; all = full resolved dictionary"
          style="font-size:11px;padding:4px 10px;border-radius:6px;border:1px solid rgba(128,128,128,0.3);background:transparent;color:inherit;cursor:pointer"
        >
          scope: {scope}
        </button>
        <button
          onClick={() => load()}
          style="font-size:11px;padding:4px 10px;border-radius:6px;border:1px solid rgba(128,128,128,0.3);background:transparent;color:inherit;cursor:pointer"
        >
          refresh
        </button>
        <button
          onClick={onReset}
          style="font-size:11px;padding:4px 10px;border-radius:6px;border:1px solid rgba(248,81,73,0.5);background:transparent;color:#f85149;cursor:pointer"
        >
          reset domain
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {/* Add a new key */}
      <div style="display:grid;grid-template-columns:minmax(140px,1fr) minmax(160px,1.6fr) auto;gap:10px;align-items:center;padding:9px 12px;border-bottom:1px solid rgba(128,128,128,0.18);background:rgba(128,128,128,0.03)">
        <input
          placeholder="new key"
          value={newKey}
          onInput={(e) => setNewKey((e.target as HTMLInputElement).value)}
          style="font-family:var(--mono,monospace);font-size:12px;padding:4px 7px;border:1px solid rgba(128,128,128,0.3);border-radius:6px;background:transparent;color:inherit"
        />
        <input
          placeholder='value as JSON, e.g. true, 42, "text", [1,2]'
          value={newValue}
          spellcheck={false}
          onInput={(e) => setNewValue((e.target as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') onAdd();
          }}
          style="font-family:var(--mono,monospace);font-size:12px;padding:4px 7px;border:1px solid rgba(128,128,128,0.3);border-radius:6px;background:transparent;color:inherit;min-width:0"
        />
        <button
          onClick={onAdd}
          disabled={!newKey.trim()}
          style="font-size:11px;padding:4px 12px;border-radius:6px;border:1px solid var(--accent);background:var(--accent);color:#000;cursor:pointer"
        >
          add
        </button>
      </div>

      {loading && !listing ? (
        <div style="padding:24px;opacity:0.6">Loading…</div>
      ) : items.length === 0 ? (
        <div style="padding:24px;opacity:0.6">No defaults{prefix ? ` matching "${prefix}"` : ''}.</div>
      ) : (
        <div>
          {items.map((entry) => (
            <Row key={entry.key} entry={entry} onSave={onSave} onDelete={onDelete} />
          ))}
        </div>
      )}

      <div style="font-size:11px;opacity:0.55;padding:10px 14px">
        Values are edited as JSON (e.g. <code>true</code>, <code>42</code>, <code>"text"</code>, <code>[1,2]</code>). scope
        “app” lists this app’s own persisted keys; “all” shows the full resolved dictionary incl. global domains.
      </div>
    </div>
  );
}
