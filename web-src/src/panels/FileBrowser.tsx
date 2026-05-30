import { useEffect, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DirListing, FileEntry } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';
import { FilePreviewDrawer } from './FilePreviewDrawer';
import { formatBytes, formatClock } from '../util/format';

/** Browses a single root (the sandbox container, or the read-only app bundle). Owns its own cwd,
 *  breadcrumbs, listing, and preview drawer; resets to `rootPath` whenever the root changes. */
export function FileBrowser({
  rootPath,
  rootName,
  readOnly = false,
}: {
  rootPath: string;
  rootName: string;
  readOnly?: boolean;
}) {
  const { t } = useI18n();
  const [cwd, setCwd] = useState(rootPath);
  const [listing, setListing] = useState<DirListing | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<FileEntry | null>(null);

  // A new root → jump back to its top.
  useEffect(() => {
    setCwd(rootPath);
  }, [rootPath]);

  const load = useCallback((path: string, signal?: AbortSignal) => {
    setLoading(true);
    setError(null);
    api
      .fsList(path, signal)
      .then((l) => {
        if (!signal?.aborted) setListing(l);
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
    load(cwd, ctrl.signal);
    return () => ctrl.abort();
  }, [cwd, load]);

  const reload = () => load(cwd);

  const rel = cwd.startsWith(rootPath) ? cwd.slice(rootPath.length).split('/').filter(Boolean) : [];
  const crumbs = [
    { name: rootName, path: rootPath },
    ...rel.map((seg, i) => ({ name: seg, path: rootPath + '/' + rel.slice(0, i + 1).join('/') })),
  ];
  const canUp = cwd !== rootPath;
  const items = listing?.items ?? [];

  return (
    <>
      <div class="crumbs">
        <button class="crumb up" disabled={!canUp} onClick={() => canUp && setCwd(cwd.slice(0, cwd.lastIndexOf('/')))}>
          ↑ {t('fs.up')}
        </button>
        <span class="crumb-div" />
        {crumbs.map((c, i) => (
          <span key={c.path}>
            {i > 0 ? <span class="crumb-sep">/</span> : null}
            <button class={`crumb ${i === crumbs.length - 1 ? 'cur' : ''}`} onClick={() => setCwd(c.path)}>
              {c.name}
            </button>
          </span>
        ))}
        <div class="spacer" />
        {listing ? <span class="count-chip">{items.length}</span> : null}
        <button class="btn" onClick={reload}>
          {t('net.refresh')}
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {loading && !listing ? (
        <Loading labelKey="fs.loading" />
      ) : items.length === 0 && !error ? (
        <EmptyState icon="∅" titleKey="fs.empty" />
      ) : (
        <div class="table-wrap">
          <table class="grid">
            <thead>
              <tr>
                <th>{t('fs.col.name')}</th>
                <th style="width:110px" class="col-num">
                  {t('fs.col.size')}
                </th>
                <th style="width:190px">{t('fs.col.modified')}</th>
              </tr>
            </thead>
            <tbody>
              {items.map((e) => (
                <tr key={e.path} onClick={() => (e.isDir ? setCwd(e.path) : setSelected(e))}>
                  <td class="name-cell">
                    <span class={`fs-ico ${e.isDir ? 'dir' : 'file'}`}>{e.isDir ? '▸' : '·'}</span>
                    <span class={e.isDir ? 'fs-dir' : 'fs-file'}>
                      {e.name}
                      {e.isDir ? '/' : ''}
                    </span>
                  </td>
                  <td class="col-num">{e.isDir ? '—' : formatBytes(e.size)}</td>
                  <td class="col-time">{e.mtime ? formatClock(e.mtime) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {selected ? (
        <FilePreviewDrawer entry={selected} readOnly={readOnly} onClose={() => setSelected(null)} onChanged={reload} />
      ) : null}
    </>
  );
}
