// Base64 helpers for request bodies. The browser's `btoa` only accepts latin1, so a UTF-8 body
// (the common case for JSON / form payloads) must be encoded byte-wise first.

/** Base64-encode a UTF-8 string. Chunked to avoid blowing the call stack on large bodies. */
export function utf8ToBase64(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = '';
  const chunk = 0x8000; // 32K code units per String.fromCharCode call
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}
