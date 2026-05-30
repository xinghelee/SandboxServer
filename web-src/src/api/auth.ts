// Token bootstrap + storage.
// On first load the SDK may hand us the token via ?token=<t>. We read it,
// stash it in sessionStorage, then strip it from the URL so it never lingers
// in history or gets copy-pasted around.

const STORAGE_KEY = 'sbx_token';
let memoryToken: string | null = null;

export function bootstrapToken(): void {
  try {
    const url = new URL(window.location.href);
    const fromQuery = url.searchParams.get('token');
    if (fromQuery) {
      memoryToken = fromQuery;
      try {
        window.sessionStorage?.setItem(STORAGE_KEY, fromQuery);
      } catch {
        /* memory fallback below keeps this page session connected */
      }
      url.searchParams.delete('token');
      const cleaned =
        url.pathname + (url.searchParams.toString() ? `?${url.searchParams}` : '') + url.hash;
      window.history.replaceState(null, '', cleaned);
    }
  } catch {
    // sessionStorage / URL parsing unavailable — degrade silently.
  }
}

export function getToken(): string | null {
  try {
    return window.sessionStorage?.getItem(STORAGE_KEY) ?? memoryToken;
  } catch {
    return memoryToken;
  }
}

export function setToken(token: string): void {
  memoryToken = token;
  try {
    window.sessionStorage?.setItem(STORAGE_KEY, token);
  } catch {
    /* ignore */
  }
}

export function clearToken(): void {
  memoryToken = null;
  try {
    window.sessionStorage?.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
}

/** Pull a token out of pasted text — either a raw token or a URL/query containing ?token=. */
export function extractToken(input: string): string | null {
  const s = input.trim();
  if (!s) return null;
  const m = s.match(/[?&]token=([^&\s]+)/);
  if (m) return decodeURIComponent(m[1]);
  return s;
}
