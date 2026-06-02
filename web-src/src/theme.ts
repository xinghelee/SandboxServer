// Theme store: dark/light, persisted to localStorage and reflected on <html data-theme>.
// An inline script in index.html applies the saved value before first paint (no flash).

import { useEffect, useState } from 'preact/hooks';

export type Theme = 'dark' | 'light';

const THEME_KEY = 'sbx_theme';

function detectTheme(): Theme {
  const stored = (typeof localStorage !== 'undefined' && localStorage.getItem(THEME_KEY)) as Theme | null;
  if (stored === 'dark' || stored === 'light') return stored;
  // Dark is the product default — only an explicit toggle (persisted above) switches to light.
  // (Deliberately does not follow `prefers-color-scheme`, which would surprise light-mode OS users
  // and mismatch index.html's dark pre-paint, causing a flash.)
  return 'dark';
}

let theme: Theme = detectTheme();
const subscribers = new Set<() => void>();

function apply(): void {
  if (typeof document !== 'undefined') document.documentElement.dataset.theme = theme;
}
apply();

export function getTheme(): Theme {
  return theme;
}

export function setTheme(next: Theme): void {
  if (next === theme) return;
  theme = next;
  try {
    localStorage.setItem(THEME_KEY, next);
  } catch {
    /* ignore */
  }
  apply();
  subscribers.forEach((fn) => fn());
}

export function useTheme() {
  const [, force] = useState(0);
  useEffect(() => {
    const fn = () => force((n) => n + 1);
    subscribers.add(fn);
    return () => {
      subscribers.delete(fn);
    };
  }, []);
  return { theme, setTheme };
}
