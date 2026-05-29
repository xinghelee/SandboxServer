// Minimal hash-based router. Routes look like #/net, #/files, #/db.

import { useEffect, useState } from 'preact/hooks';

export function currentRoute(): string {
  const hash = window.location.hash || '';
  const path = hash.replace(/^#/, '');
  return path.startsWith('/') ? path : `/${path}`;
}

export function navigate(path: string): void {
  const normalized = path.startsWith('/') ? path : `/${path}`;
  window.location.hash = `#${normalized}`;
}

export function useRoute(): string {
  const [route, setRoute] = useState<string>(currentRoute());
  useEffect(() => {
    const onChange = () => setRoute(currentRoute());
    window.addEventListener('hashchange', onChange);
    return () => window.removeEventListener('hashchange', onChange);
  }, []);
  return route;
}
