import { useEffect, useRef, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { FileEntry } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { formatBytes, formatClock } from '../util/format';

interface Props {
  entry: FileEntry;
  onClose: () => void;
  onChanged: () => void; // reload the directory after a write/delete
}

function isTextual(mime: string): boolean {
  return (
    mime.startsWith('text/') ||
    /json|xml|javascript|markdown|x-www-form-urlencoded|svg/.test(mime)
  );
}

export function FilePreviewDrawer({ entry, onClose, onChanged }: Props) {
  const { t } = useI18n();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState<string | null>(null);
  const [imgUrl, setImgUrl] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState('');
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [plistFormat, setPlistFormat] = useState<string | null>(null);
  const objectUrl = useRef<string | null>(null);

  // Plists and .strings in a built bundle are usually BINARY — decode them to readable JSON via the
  // bundle plugin instead of showing the raw (garbled) bytes. Editing is disabled for these.
  const isPlist = /\.(plist|strings)$/i.test(entry.name);
  const textual = isTextual(entry.mime);
  const image = entry.mime.startsWith('image/');

  useEffect(() => {
    const ctrl = new AbortController();
    setLoading(true);
    setError(null);
    setText(null);
    setImgUrl(null);
    setEditing(false);
    setSaved(false);
    setPlistFormat(null);

    (async () => {
      try {
        if (isPlist) {
          try {
            const decoded = await api.bundlePlist(entry.path, ctrl.signal);
            if (!ctrl.signal.aborted) {
              const json = JSON.stringify(decoded.json, null, 2);
              setText(json);
              setDraft(json);
              setPlistFormat(decoded.format);
            }
          } catch {
            // Not a decodable plist after all — fall back to the raw bytes as text.
            const res = await api.fsRead(entry.path, ctrl.signal);
            const body = await res.text();
            if (!ctrl.signal.aborted) {
              setText(body);
              setDraft(body);
            }
          }
        } else if (textual) {
          const res = await api.fsRead(entry.path, ctrl.signal);
          const body = await res.text();
          if (!ctrl.signal.aborted) {
            setText(body);
            setDraft(body);
          }
        } else if (image) {
          const res = await api.fsRead(entry.path, ctrl.signal);
          const blob = await res.blob();
          if (!ctrl.signal.aborted) {
            const url = URL.createObjectURL(blob);
            objectUrl.current = url;
            setImgUrl(url);
          }
        }
      } catch (e) {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      } finally {
        if (!ctrl.signal.aborted) setLoading(false);
      }
    })();

    return () => {
      ctrl.abort();
      if (objectUrl.current) {
        URL.revokeObjectURL(objectUrl.current);
        objectUrl.current = null;
      }
    };
  }, [entry.path]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !editing) onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose, editing]);

  async function download() {
    try {
      const res = await api.fsRead(entry.path);
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = entry.name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    }
  }

  async function save() {
    setSaving(true);
    setError(null);
    try {
      await api.fsWrite(entry.path, draft);
      setText(draft);
      setEditing(false);
      setSaved(true);
      onChanged();
    } catch (e) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  async function remove() {
    if (!confirm(t('fs.confirmDelete', { name: entry.name }))) return;
    try {
      await api.fsDelete(entry.path);
      onChanged();
      onClose();
    } catch (e) {
      setError(e instanceof ApiRequestError ? e.message : String(e));
    }
  }

  return (
    <>
      <div class="drawer-scrim" onClick={onClose} />
      <aside class="drawer">
        <div class="drawer-head">
          <span class="d-method">{entry.mime.split(';')[0]}</span>
          <span class="d-url" title={entry.path}>
            {entry.name}
          </span>
          <button class="x" onClick={onClose} aria-label="Close">
            ×
          </button>
        </div>

        <div class="fs-toolbar">
          <span class="muted">
            {formatBytes(entry.size)} · {formatClock(entry.mtime)}
          </span>
          <div class="spacer" />
          {saved ? <span class="saved-flag">✓ {t('fs.saved')}</span> : null}
          {plistFormat ? <span class="chip-sm">plist · {plistFormat}</span> : null}
          {textual && !editing && !isPlist ? (
            <button class="btn" onClick={() => { setDraft(text ?? ''); setEditing(true); }}>
              {t('fs.edit')}
            </button>
          ) : null}
          {editing ? (
            <>
              <button class="btn" onClick={() => setEditing(false)}>
                {t('fs.cancel')}
              </button>
              <button class="btn primary" onClick={save} disabled={saving}>
                {t('fs.save')}
              </button>
            </>
          ) : null}
          <button class="btn" onClick={download}>
            {t('fs.download')}
          </button>
          <button class="btn danger" onClick={remove}>
            {t('fs.delete')}
          </button>
        </div>

        <div class="drawer-body">
          {error ? <div class="error-banner">{error}</div> : null}
          {loading ? (
            <Loading labelKey="fs.loading" />
          ) : editing ? (
            <textarea class="fs-editor" value={draft} onInput={(e) => setDraft((e.target as HTMLTextAreaElement).value)} spellcheck={false} />
          ) : text !== null ? (
            <pre class="body">{text}</pre>
          ) : image && imgUrl ? (
            <div class="fs-image">
              <img src={imgUrl} alt={entry.name} />
            </div>
          ) : (
            <div class="empty-state">
              <div class="es-icon">⛁</div>
              <div class="es-title">{t('fs.binary', { size: formatBytes(entry.size) })}</div>
              <div class="es-sub">{entry.mime}</div>
            </div>
          )}
        </div>
      </aside>
    </>
  );
}
