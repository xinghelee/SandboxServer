import type { NetRequestSummary } from '../api/types';

export function statusClassNum(status: number | null): string {
  if (status === null || status === undefined) return 'pending';
  const c = Math.floor(status / 100);
  return `s${c >= 1 && c <= 5 ? c : 1}`;
}

export function formatBytes(n: number | null | undefined): string {
  if (n === null || n === undefined) return '—';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export function formatDuration(ms: number | null | undefined): string {
  if (ms === null || ms === undefined) return '—';
  if (ms < 1000) return `${Math.round(ms)} ms`;
  return `${(ms / 1000).toFixed(2)} s`;
}

export function formatClock(unixMsOrS: number | null | undefined): string {
  if (!unixMsOrS) return '—';
  // Heuristic: values below ~1e12 are seconds, otherwise milliseconds.
  const ms = unixMsOrS < 1e12 ? unixMsOrS * 1000 : unixMsOrS;
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return '—';
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  const mmm = String(d.getMilliseconds()).padStart(3, '0');
  return `${hh}:${mm}:${ss}.${mmm}`;
}

// Shorten a full URL to host + path for the table column.
export function shortUrl(url: string): string {
  try {
    const u = new URL(url);
    return `${u.host}${u.pathname}${u.search}`;
  } catch {
    return url;
  }
}

// Pretty-print a body. JSON gets re-indented; everything else passes through.
export function prettyBody(body: string | null | undefined): string {
  if (body === null || body === undefined || body === '') return '';
  const trimmed = body.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return JSON.stringify(JSON.parse(trimmed), null, 2);
    } catch {
      return body;
    }
  }
  return body;
}

// Merge a completed payload into an existing summary row.
export function mergeCompleted(
  row: NetRequestSummary,
  patch: Partial<NetRequestSummary>,
): NetRequestSummary {
  return { ...row, ...patch };
}
