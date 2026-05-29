import { useEffect, useState } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { DbDescriptor } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';

interface State {
  loading: boolean;
  error: string | null;
  notImplemented: boolean;
  dbs: DbDescriptor[];
}

export function DbPanel() {
  const { t } = useI18n();
  const [state, setState] = useState<State>({ loading: true, error: null, notImplemented: false, dbs: [] });

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .databases(ctrl.signal)
      .then((res) => {
        if (ctrl.signal.aborted) return;
        setState({ loading: false, error: null, notImplemented: false, dbs: res.items });
      })
      .catch((e: unknown) => {
        if (ctrl.signal.aborted) return;
        if (e instanceof ApiRequestError && e.isNotImplemented) {
          setState({ loading: false, error: null, notImplemented: true, dbs: [] });
        } else if (e instanceof ApiRequestError) {
          setState({ loading: false, error: e.message, notImplemented: false, dbs: [] });
        } else {
          setState({ loading: false, error: String(e), notImplemented: false, dbs: [] });
        }
      });
    return () => ctrl.abort();
  }, []);

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('db.title')}</h2>
        {!state.loading && state.dbs.length > 0 ? (
          <span class="count-chip">{t('db.found', { n: state.dbs.length })}</span>
        ) : null}
        <div class="spacer" />
      </div>

      {state.error ? <div class="error-banner">{state.error}</div> : null}

      {state.loading ? (
        <Loading labelKey="db.loading" />
      ) : state.notImplemented ? (
        <EmptyState icon="▤" titleKey="db.notimpl.title" subKey="db.notimpl.sub" tag="GET /db → 501" />
      ) : state.dbs.length === 0 ? (
        <EmptyState icon="▤" titleKey="db.empty.title" subKey="db.empty.sub" />
      ) : (
        <>
          <div class="db-list">
            {state.dbs.map((db) => (
              <div class="db-card" key={db.id}>
                <span class={`engine-badge ${db.engine}`}>{db.engine}</span>
                <div style="flex:1; min-width:0">
                  <div class="db-name">{db.name}</div>
                  <div class="db-path" title={db.path}>
                    {db.path}
                  </div>
                </div>
                {db.readOnly ? <span class="ro-badge">{t('db.readonly')}</span> : null}
              </div>
            ))}
          </div>
          <EmptyState icon="⌨" titleKey="db.soon.title" subKey="db.soon.sub" tag="tables / schema / query → 501" />
        </>
      )}
    </div>
  );
}
