// Token bootstrap + storage.
// On first load the SDK may hand us the token via ?token=<t>. We read it,
// stash it in sessionStorage, then strip it from the URL so it never lingers
// in history or gets copy-pasted around.

const STORAGE_KEY = 'sbx_token';

export function bootstrapToken(): void {
  try {
    const url = new URL(window.location.href);
    const fromQuery = url.searchParams.get('token');
    if (fromQuery) {
      sessionStorage.setItem(STORAGE_KEY, fromQuery);
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
    return sessionStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

export function setToken(token: string): void {
  try {
    sessionStorage.setItem(STORAGE_KEY, token);
  } catch {
    /* ignore */
  }
}

export function clearToken(): void {
  try {
    sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
}
