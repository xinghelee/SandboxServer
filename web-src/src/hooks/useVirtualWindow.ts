import { useEffect, useState } from 'preact/hooks';
import type { RefObject } from 'preact';

export interface VirtualWindow {
  /** First row index to render (inclusive). */
  start: number;
  /** One past the last row index to render (exclusive). */
  end: number;
  /** Spacer height above the window, in px (keeps the scrollbar honest). */
  padTop: number;
  /** Spacer height below the window, in px. */
  padBottom: number;
}

/**
 * Dependency-free fixed-row-height windowing. Watches a bounded scroll container and reports the
 * slice of rows that intersect the viewport (plus an overscan margin), with spacer heights for the
 * rows above/below. The caller renders `padTop`/`padBottom` as empty spacer elements so the
 * scrollbar and offsets stay correct while only the visible window hits the DOM.
 *
 * Fixed height only — used for the nowrap grid rows in the network and DB panels. The logs stream
 * has variable-height (wrapping) rows and uses CSS `content-visibility` instead.
 */
export function useVirtualWindow(
  scrollRef: RefObject<HTMLElement>,
  opts: { count: number; rowHeight: number; enabled?: boolean; overscan?: number },
): VirtualWindow {
  const { count, rowHeight, enabled = true, overscan = 10 } = opts;
  const [scrollTop, setScrollTop] = useState(0);
  const [viewport, setViewport] = useState(0);

  useEffect(() => {
    const el = scrollRef.current;
    if (!enabled || !el) return;
    const onScroll = () => setScrollTop(el.scrollTop);
    const measure = () => setViewport(el.clientHeight);
    measure();
    setScrollTop(el.scrollTop);
    el.addEventListener('scroll', onScroll, { passive: true });
    const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(measure) : null;
    ro?.observe(el);
    return () => {
      el.removeEventListener('scroll', onScroll);
      ro?.disconnect();
    };
    // `enabled` flips when the list mounts/unmounts (e.g. empty→populated), re-binding the listener
    // to the real element; `count` deliberately isn't a dep so streaming rows don't churn it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scrollRef, enabled]);

  if (!enabled || count === 0 || rowHeight <= 0) {
    return { start: 0, end: count, padTop: 0, padBottom: 0 };
  }
  // Before the first measure, assume a generous viewport so we still window (never render all rows).
  const vp = viewport || 800;
  const perScreen = Math.ceil(vp / rowHeight);
  const start = Math.max(0, Math.min(count - 1, Math.floor(scrollTop / rowHeight) - overscan));
  const end = Math.min(count, start + perScreen + overscan * 2);
  return {
    start,
    end,
    padTop: start * rowHeight,
    padBottom: Math.max(0, (count - end) * rowHeight),
  };
}
