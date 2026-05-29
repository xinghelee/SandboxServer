import { useEffect, useMemo, useRef, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { HierarchyNode, HierarchyTree } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';

type FlatNode = Omit<HierarchyNode, 'children'>;

function flatten(root: HierarchyNode | null): FlatNode[] {
  const out: FlatNode[] = [];
  const walk = (n: HierarchyNode) => {
    const { children, ...rest } = n;
    out.push(rest);
    children.forEach(walk);
  };
  if (root) walk(root);
  return out;
}

function depthColor(depth: number): string {
  return `hsl(${(depth * 38 + 198) % 360} 75% 60%)`;
}
function shortName(cls: string): string {
  const i = cls.indexOf('<');
  return i > 0 ? cls.slice(0, i) : cls;
}

/** Left sidebar: the view tree as an indented, clickable list. */
function TreeRows({
  node,
  selectedId,
  onSelect,
}: {
  node: HierarchyNode;
  selectedId: number | null;
  onSelect: (id: number) => void;
}) {
  return (
    <>
      <div
        class={`h3d-tree-row ${node.id === selectedId ? 'sel' : ''} ${node.hidden ? 'hid' : ''}`}
        style={`padding-left:${node.depth * 11 + 8}px`}
        title={node.cls}
        onClick={() => onSelect(node.id)}
      >
        <span class="dot" style={`background:${depthColor(node.depth)}`} />
        <span class="cls">{shortName(node.cls)}</span>
        {node.label ? <span class="lbl">{node.label}</span> : null}
      </div>
      {node.children.map((c) => (
        <TreeRows key={c.id} node={c} selectedId={selectedId} onSelect={onSelect} />
      ))}
    </>
  );
}

/**
 * 3D exploded view-hierarchy inspector (Xcode "Debug View Hierarchy"-style), pure CSS 3D — no deps.
 * Left: the view tree (click to select). Center: each view as a slab at its window-space frame,
 * pushed back in Z by depth and textured with its real rendered content (leaf/content views) —
 * drag anywhere to orbit, click a slab to select. Right: the selected node's details. Same data
 * powers the ui_hierarchy MCP tool.
 */
export function HierarchyPanel() {
  const { t } = useI18n();
  const [tree, setTree] = useState<HierarchyTree | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [gap, setGap] = useState(22);
  const [maxDepth, setMaxDepth] = useState(60);
  const [showHidden, setShowHidden] = useState(false);
  const [showContent, setShowContent] = useState(true);
  const [showBorders, setShowBorders] = useState(true);
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [rx, setRx] = useState(-18);
  const [ry, setRy] = useState(-26);
  const [showDetail, setShowDetail] = useState(true);
  const [treeWidth, setTreeWidth] = useState<number>(() => {
    const n = Number(typeof localStorage !== 'undefined' ? localStorage.getItem('sbx_hier_tw') : '');
    return n >= 160 && n <= 640 ? n : 240;
  });

  const stackRef = useRef<HTMLDivElement>(null);
  const treeRef = useRef<HTMLDivElement>(null);
  const rotRef = useRef({ rx: -18, ry: -26 });
  const dragRef = useRef<{ x: number; y: number; rx: number; ry: number; id: number | null; moved: boolean; pid: number } | null>(null);
  const resizeRef = useRef<{ startX: number; startW: number; cur: number; pid: number } | null>(null);

  const load = useCallback(
    (signal?: AbortSignal) => {
      setLoading(true);
      setError(null);
      api
        .hierarchy({ maxDepth: 60, maxNodes: 1200, thumbs: showContent }, signal)
        .then((res) => {
          setTree(res);
          setSelectedId(null);
        })
        .catch((e: unknown) => {
          if (!signal?.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
        })
        .finally(() => {
          if (!signal?.aborted) setLoading(false);
        });
    },
    [showContent],
  );

  useEffect(() => {
    const ctrl = new AbortController();
    load(ctrl.signal);
    return () => ctrl.abort();
  }, [load]);

  // One persistent set of drag listeners (no per-drag add/remove → no unmount leak). They no-op
  // unless a drag is in progress, and apply rotation straight to the stack element (no per-frame
  // setState, so the 1200-slab layer list isn't rebuilt while orbiting).
  const applyRot = useCallback((rxv: number, ryv: number) => {
    const el = stackRef.current;
    if (el) {
      const base = el.style.transform.replace(/rotateX[^)]*\)\s*rotateY[^)]*\)/, '').trim();
      el.style.transform = `${base || 'translate(-50%,-50%)'} rotateX(${rxv}deg) rotateY(${ryv}deg)`;
    }
  }, []);

  useEffect(() => {
    const move = (e: PointerEvent) => {
      const rz = resizeRef.current;
      if (rz) {
        if (e.pointerId !== rz.pid) return; // ignore other pointers (pinch / hybrid mouse+touch)
        const nw = Math.max(160, Math.min(640, rz.startW + (e.clientX - rz.startX)));
        rz.cur = nw;
        if (treeRef.current) treeRef.current.style.flexBasis = `${nw}px`;
        return;
      }
      const d = dragRef.current;
      if (!d || e.pointerId !== d.pid) return;
      if (Math.abs(e.clientX - d.x) > 3 || Math.abs(e.clientY - d.y) > 3) d.moved = true;
      const ryv = d.ry + (e.clientX - d.x) * 0.4;
      const rxv = Math.max(-89, Math.min(89, d.rx - (e.clientY - d.y) * 0.4));
      rotRef.current = { rx: rxv, ry: ryv };
      applyRot(rxv, ryv);
    };
    const up = (e: PointerEvent) => {
      const rz = resizeRef.current;
      if (rz) {
        if (e.pointerId !== rz.pid) return;
        resizeRef.current = null;
        setTreeWidth(rz.cur);
        try {
          localStorage.setItem('sbx_hier_tw', String(rz.cur));
        } catch {
          /* private mode */
        }
        return;
      }
      const d = dragRef.current;
      if (!d || e.pointerId !== d.pid) return;
      dragRef.current = null;
      if (d.moved) {
        setRx(rotRef.current.rx);
        setRy(rotRef.current.ry);
      } else if (d.id != null) {
        setSelectedId(d.id);
      }
    };
    // Pointer (not mouse) events so orbit/resize work on touch too; touch pointers are implicitly
    // captured to the pressed element and the events still bubble to window. pointercancel (browser
    // stole the gesture, etc.) ends the drag like an up.
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', up);
    return () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', up);
    };
  }, [applyRot]);

  const onStageDown = useCallback((e: PointerEvent) => {
    if (dragRef.current || resizeRef.current) return; // ignore a second finger mid-gesture
    const idAttr = (e.target as HTMLElement).dataset?.layerId;
    dragRef.current = {
      x: e.clientX,
      y: e.clientY,
      rx: rotRef.current.rx,
      ry: rotRef.current.ry,
      id: idAttr != null ? +idAttr : null,
      moved: false,
      pid: e.pointerId,
    };
  }, []);

  const nodes = useMemo(() => flatten(tree?.root ?? null), [tree]);
  const treeMaxDepth = useMemo(() => nodes.reduce((m, n) => Math.max(m, n.depth), 0), [nodes]);
  const selected = useMemo(() => nodes.find((n) => n.id === selectedId) ?? null, [nodes, selectedId]);
  const w = tree?.width || 390;
  const h = tree?.height || 844;
  const scale = 300 / w;
  const visible = useMemo(
    () => nodes.filter((n) => n.depth <= maxDepth && (showHidden || !n.hidden)),
    [nodes, maxDepth, showHidden],
  );

  // Memoized slab list — rebuilt only when its inputs change, NOT while orbiting.
  const layerEls = useMemo(
    () =>
      visible
        .map((n) => {
          // Clamp to the on-screen window: scrollable content has off-screen / oversized views
          // whose window frames sit far below the screen, which otherwise draw a long empty tail.
          const ix0 = Math.max(0, n.x);
          const iy0 = Math.max(0, n.y);
          const ix1 = Math.min(w, n.x + n.w);
          const iy1 = Math.min(h, n.y + n.h);
          if (ix1 - ix0 < 0.5 || iy1 - iy0 < 0.5) return null; // fully off-screen → drop
          let fill: string;
          if (showContent && n.thumb) {
            // Show only the visible crop of the full-view thumbnail.
            fill =
              `background-image:url(data:image/png;base64,${n.thumb});` +
              `background-size:${n.w * scale}px ${n.h * scale}px;` +
              `background-position:${(n.x - ix0) * scale}px ${(n.y - iy0) * scale}px;background-repeat:no-repeat;`;
          } else {
            fill = `background:${depthColor(n.depth)}1f;`;
          }
          const border = showBorders ? `border-color:${depthColor(n.depth)};` : 'border-color:transparent;';
          const style =
            `left:${ix0 * scale}px;top:${iy0 * scale}px;width:${Math.max((ix1 - ix0) * scale, 1)}px;` +
            `height:${Math.max((iy1 - iy0) * scale, 1)}px;transform:translateZ(${n.depth * gap}px);${border}${fill}`;
          return (
            <div
              key={n.id}
              data-layer-id={n.id}
              class={`h3d-layer ${n.id === selectedId ? 'sel' : ''} ${n.hidden ? 'hid' : ''}`}
              style={style}
              title={`${shortName(n.cls)}  ${Math.round(n.w)}×${Math.round(n.h)}`}
            />
          );
        })
        .filter(Boolean),
    [visible, gap, scale, selectedId, showContent, showBorders, w, h],
  );

  const reset = () => {
    rotRef.current = { rx: -18, ry: -26 };
    setRx(-18);
    setRy(-26);
    setGap(22);
    applyRot(-18, -26);
  };

  if (loading && !tree) {
    return (
      <div class="panel">
        <Loading labelKey="hier.loading" />
      </div>
    );
  }
  if (tree && !tree.supported) {
    return (
      <div class="panel">
        <EmptyState icon="⧉" titleKey="hier.unsupported.title" subKey="hier.unsupported.sub" />
      </div>
    );
  }

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('hier.title')}</h2>
        <span class="count-chip">{t('hier.count', { n: visible.length, total: nodes.length })}</span>
        {tree?.truncated ? <span class="count-chip warn">{t('hier.truncated')}</span> : null}
        <div class="spacer" />
        <label class="h3d-ctl">
          {t('hier.explode')}
          <input type="range" min="0" max="60" value={gap} onInput={(e) => setGap(+(e.target as HTMLInputElement).value)} />
        </label>
        <label class="h3d-ctl">
          {t('hier.depth')}
          <input type="range" min="0" max={treeMaxDepth || 1} value={maxDepth} onInput={(e) => setMaxDepth(+(e.target as HTMLInputElement).value)} />
        </label>
        <button class={`btn ${showContent ? 'primary' : ''}`} onClick={() => setShowContent((v) => !v)}>
          {t('hier.content')}
        </button>
        <button class={`btn ${showBorders ? 'primary' : ''}`} onClick={() => setShowBorders((v) => !v)}>
          {t('hier.borders')}
        </button>
        <button class={`btn ${showHidden ? 'primary' : ''}`} onClick={() => setShowHidden((v) => !v)}>
          {t('hier.hidden')}
        </button>
        <button class={`btn ${showDetail ? 'primary' : ''}`} onClick={() => setShowDetail((v) => !v)}>
          {t('hier.props')}
        </button>
        <button class="btn" onClick={reset}>
          {t('hier.reset')}
        </button>
        <button class="btn" onClick={() => load()}>
          {t('hier.refresh')}
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      <div class="h3d-layout">
        <div class="h3d-tree" ref={treeRef} style={`flex:0 0 ${treeWidth}px`}>
          {tree?.root ? <TreeRows node={tree.root} selectedId={selectedId} onSelect={setSelectedId} /> : null}
        </div>
        <div
          class="h3d-resizer"
          title={t('hier.resize')}
          onPointerDown={(e) => {
            if (dragRef.current || resizeRef.current) return;
            const w = treeRef.current?.offsetWidth ?? treeWidth;
            resizeRef.current = { startX: e.clientX, startW: w, cur: w, pid: e.pointerId };
          }}
        />

        <div class="h3d-wrap" onPointerDown={onStageDown}>
          <div
            class="h3d-stack"
            ref={stackRef}
            style={`width:${w * scale}px;height:${h * scale}px;transform:translate(-50%,-50%) rotateX(${rx}deg) rotateY(${ry}deg)`}
          >
            {layerEls}
          </div>
          <div class="h3d-hint">{t('hier.hint')}</div>
        </div>

        {showDetail ? (
        <div class="h3d-side">
          {selected ? (
            <div class="h3d-detail">
              <div class="h3d-cls" style={`color:${depthColor(selected.depth)}`}>{selected.cls}</div>
              <dl>
                <dt>{t('hier.d.depth')}</dt>
                <dd>{selected.depth}</dd>
                <dt>{t('hier.d.frame')}</dt>
                <dd class="mono">
                  ({Math.round(selected.x)}, {Math.round(selected.y)}) · {Math.round(selected.w)}×{Math.round(selected.h)}
                </dd>
                <dt>{t('hier.d.alpha')}</dt>
                <dd>
                  {selected.alpha.toFixed(2)}
                  {selected.hidden ? ' · hidden' : ''}
                </dd>
                {selected.bg ? (
                  <>
                    <dt>{t('hier.d.bg')}</dt>
                    <dd class="mono">
                      <span class="h3d-swatch" style={`background:${selected.bg}`} />
                      {selected.bg}
                    </dd>
                  </>
                ) : null}
                {selected.label ? (
                  <>
                    <dt>{t('hier.d.label')}</dt>
                    <dd>{selected.label}</dd>
                  </>
                ) : null}
              </dl>
            </div>
          ) : (
            <div class="h3d-detail muted">{t('hier.pick')}</div>
          )}
        </div>
        ) : null}
      </div>
    </div>
  );
}
