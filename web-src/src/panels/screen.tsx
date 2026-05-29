import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import { api, ApiRequestError } from '../api/client';
import type { ScreenInfo } from '../api/types';
import { useI18n } from '../i18n';
import { Loading } from '../components/Spinner';
import { EmptyState } from '../components/EmptyState';

const POLL_MS = 200; // ~5 fps live mirror
const FRAME_MAX_WIDTH = 460;
const FRAME_QUALITY = 0.5;

interface Ripple { x: number; y: number; key: number }

/**
 * Live screen mirror + control. Polls /screen/frame for JPEG frames (auth header → blob → object
 * URL) and maps browser clicks back to window points for /screen/tap. A text box drives
 * /screen/text (type into the focused field) and /screen/paste. iOS-only; degrades to a notice.
 */
export function ScreenPanel() {
  const { t } = useI18n();
  const [info, setInfo] = useState<ScreenInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [frameUrl, setFrameUrl] = useState<string | null>(null);
  const [paused, setPaused] = useState(false);
  const [interact, setInteract] = useState(true);
  const [text, setText] = useState('');
  const [lastAction, setLastAction] = useState<string | null>(null);
  const [ripples, setRipples] = useState<Ripple[]>([]);

  const imgRef = useRef<HTMLImageElement>(null);
  const rippleKey = useRef(0);

  useEffect(() => {
    const ctrl = new AbortController();
    api
      .screenInfo(ctrl.signal)
      .then(setInfo)
      .catch((e: unknown) => {
        if (!ctrl.signal.aborted) setError(e instanceof ApiRequestError ? e.message : String(e));
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoading(false);
      });
    return () => ctrl.abort();
  }, []);

  // Live frame loop — chained setTimeout so polls never overlap; revoke old object URLs.
  useEffect(() => {
    if (!info?.supported || paused) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      try {
        const res = await api.screenFrame(FRAME_MAX_WIDTH, FRAME_QUALITY);
        const blob = await res.blob();
        if (cancelled) return;
        const url = URL.createObjectURL(blob);
        setFrameUrl((prev) => {
          if (prev) URL.revokeObjectURL(prev);
          return url;
        });
        setError(null);
      } catch (e) {
        if (!cancelled) setError(e instanceof ApiRequestError ? e.message : String(e));
      }
      if (!cancelled) timer = setTimeout(tick, POLL_MS);
    };
    tick();
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [info?.supported, paused]);

  // Revoke the final URL on unmount.
  useEffect(
    () => () => {
      setFrameUrl((prev) => {
        if (prev) URL.revokeObjectURL(prev);
        return null;
      });
    },
    [],
  );

  const dragRef = useRef<{ px: number; py: number; x: number; y: number; t: number } | null>(null);

  const mapPoint = useCallback(
    (e: MouseEvent) => {
      const img = imgRef.current!;
      const rect = img.getBoundingClientRect();
      const px = e.clientX - rect.left;
      const py = e.clientY - rect.top;
      return {
        px,
        py,
        x: Math.round((px / rect.width) * (info?.width ?? 1)),
        y: Math.round((py / rect.height) * (info?.height ?? 1)),
      };
    },
    [info],
  );

  const onDown = useCallback(
    (e: MouseEvent) => {
      if (!interact || !info || !imgRef.current) return;
      dragRef.current = { ...mapPoint(e), t: Date.now() };
    },
    [interact, info, mapPoint],
  );

  const onUp = useCallback(
    (e: MouseEvent) => {
      const start = dragRef.current;
      dragRef.current = null;
      if (!interact || !info || !start || !imgRef.current) return;
      const end = mapPoint(e);
      const ripKey = rippleKey.current++;
      setRipples((r) => [...r, { x: end.px, y: end.py, key: ripKey }]);
      setTimeout(() => setRipples((r) => r.filter((it) => it.key !== ripKey)), 500);
      const dist = Math.hypot(end.px - start.px, end.py - start.py);
      const report = (label: string) => (res: { detail: string }) => setLastAction(`${label} → ${res.detail}`);
      const fail = (err: unknown) => setLastAction(err instanceof ApiRequestError ? err.message : String(err));
      if (dist < 8) {
        api.screenTap(end.x, end.y).then(report(`tap (${end.x},${end.y})`)).catch(fail);
      } else {
        const dur = Math.max(0.05, Math.min((Date.now() - start.t) / 1000 || 0.25, 1.5));
        api.screenSwipe({ x: start.x, y: start.y }, { x: end.x, y: end.y }, dur).then(report('swipe')).catch(fail);
      }
    },
    [interact, info, mapPoint],
  );

  const send = useCallback(
    (kind: 'type' | 'paste' | 'clear') => {
      if (!text && kind !== 'clear') return;
      const p =
        kind === 'paste' ? api.screenPaste(text) : api.screenType(text, kind === 'clear');
      p.then((res) => setLastAction(`${kind} → ${res.detail}`)).catch((err: unknown) =>
        setLastAction(err instanceof ApiRequestError ? err.message : String(err)),
      );
    },
    [text],
  );

  if (loading) {
    return (
      <div class="panel">
        <Loading labelKey="screen.loading" />
      </div>
    );
  }

  if (info && !info.supported) {
    return (
      <div class="panel">
        <EmptyState icon="▱" titleKey="screen.unsupported.title" subKey="screen.unsupported.sub" />
      </div>
    );
  }

  return (
    <div class="panel">
      <div class="panel-toolbar">
        <h2>{t('screen.title')}</h2>
        {info ? (
          <span class="count-chip">
            {Math.round(info.width)}×{Math.round(info.height)} @{info.scale}x
          </span>
        ) : null}
        {info?.gestures ? <span class="count-chip">{t('screen.gestures')}</span> : null}
        <div class="spacer" />
        <button class={`btn ${interact ? 'primary' : ''}`} onClick={() => setInteract((v) => !v)}>
          {interact ? t('screen.interact.on') : t('screen.interact.off')}
        </button>
        <button class="btn" onClick={() => setPaused((v) => !v)}>
          {paused ? t('screen.resume') : t('screen.pause')}
        </button>
      </div>

      {error ? <div class="error-banner">{error}</div> : null}

      <div class="screen-layout">
        <div class={`screen-stage ${interact ? 'interactive' : ''}`}>
          {frameUrl ? (
            <div class="screen-frame">
              <img
                ref={imgRef}
                class="screen-img"
                src={frameUrl}
                draggable={false}
                onMouseDown={onDown}
                onMouseUp={onUp}
                onMouseLeave={() => {
                  dragRef.current = null;
                }}
                alt="device screen"
              />
              {ripples.map((r) => (
                <span class="screen-ripple" key={r.key} style={`left:${r.x}px;top:${r.y}px`} />
              ))}
            </div>
          ) : (
            <Loading labelKey="screen.waiting" />
          )}
        </div>

        <div class="screen-side">
          <div class="screen-hint">{interact ? t('screen.hint.tap') : t('screen.hint.look')}</div>
          <div class="screen-input">
            <input
              class="input"
              type="text"
              placeholder={t('screen.text.ph')}
              value={text}
              onInput={(e) => setText((e.target as HTMLInputElement).value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') send('type');
              }}
            />
            <div class="screen-btns">
              <button class="btn" onClick={() => send('type')}>
                {t('screen.type')}
              </button>
              <button class="btn" onClick={() => send('paste')}>
                {t('screen.paste')}
              </button>
              <button class="btn" onClick={() => send('clear')}>
                {t('screen.clearType')}
              </button>
            </div>
          </div>
          {lastAction ? <div class="screen-action mono">{lastAction}</div> : null}
        </div>
      </div>
    </div>
  );
}
