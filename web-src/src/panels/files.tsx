import { useEffect, useState, useMemo } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { FsRoot } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';
import { FileBrowser } from './FileBrowser';

/**
 * Browses the app SANDBOX (the writable data container + any host-registered extra roots). The
 * read-only app bundle is intentionally NOT shown here — the Payload is browsed in the Bundle panel.
 */
export function FilesPanel() {
  const { t } = useI18n();
  const [roots, setRoots] = useState<FsRoot[]>([]);
  const [activePath, setActivePath] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);

  // Sandbox = the writable roots; the read-only bundle root lives in the Bundle panel.
  const sandboxRoots = useMemo(() => roots.filter((r) => !r.readOnly), [roots]);

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .fsRoots(ctrl.signal)
      .then((r) => {
        if (ctrl.signal.aborted) return;
        setRoots(r.items);
        setActivePath(r.items.find((x) => !x.readOnly)?.path ?? null);
      })
      .catch((e: unknown) => {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoaded(true);
      });
    return () => ctrl.abort();
  }, []);

  const active = sandboxRoots.find((r) => r.path === activePath) ?? sandboxRoots[0];

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('fs.title')}</h2>
        <div class="spacer" />
        {sandboxRoots.length > 1 ? (
          <div class="root-chips">
            {sandboxRoots.map((r) => (
              <button
                key={r.path}
                class={`root-chip ${active?.path === r.path ? 'on' : ''}`}
                onClick={() => setActivePath(r.path)}
                title={r.path}
              >
                {r.name}
              </button>
            ))}
          </div>
        ) : null}
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      {!loaded ? (
        <Loading labelKey="fs.loading" />
      ) : active ? (
        <FileBrowser rootPath={active.path} rootName={active.name} readOnly={false} />
      ) : (
        <EmptyState icon="∅" titleKey="fs.empty" />
      )}
    </div>
  );
}
