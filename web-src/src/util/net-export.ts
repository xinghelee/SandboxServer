// Serialize a captured request into a reproducible `curl` command or a HAR 1.2 archive.
// Both consume the full NetRequestDetail (headers + bodies), so they are offered from the
// detail drawer once the transaction has loaded.

import type { NetRequestDetail } from '../api/types';

// POSIX single-quote escaping: wrap in single quotes; a literal ' becomes '\'' (close, escaped
// quote, reopen). Safe for arbitrary bytes in sh/bash/zsh.
function shq(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

// The server returns a 64 KB-capped *preview* of bodies, not the raw bytes (see
// TransactionStore.preview): a binary body becomes "<binary N bytes>", a non-UTF8 body becomes
// "<N bytes, non-UTF8>", and an oversize text body is "<body>\n… (truncated, N bytes total)".
// Sensitive request headers are replaced with "<redacted>" (TransactionStore.redact). Emitting
// any of these verbatim would produce a misleading curl/HAR, so we detect and annotate instead.
const REDACTED = '<redacted>';
const PLACEHOLDER_BODY = /^<binary \d+ bytes>$|^<\d+ bytes, non-UTF8>$/;
const TRUNCATION_SUFFIX = /\n… \(truncated, (\d+) bytes total\)$/;

interface BodyInfo {
  usable: string | null; // the real body, or null when it's a preview placeholder/truncated
  note: string | null; // human-readable reason it was omitted
}

function classifyBody(body: string | null | undefined): BodyInfo {
  if (body == null || body === '') return { usable: null, note: null };
  if (PLACEHOLDER_BODY.test(body)) return { usable: null, note: body };
  const m = body.match(TRUNCATION_SUFFIX);
  if (m) return { usable: null, note: `truncated preview (${m[1]} bytes total)` };
  return { usable: body, note: null };
}

function redactedNames(headers?: Record<string, string>): string[] {
  return headers ? Object.entries(headers).filter(([, v]) => v === REDACTED).map(([k]) => k) : [];
}

/** Build a multi-line `curl` command reproducing the request. */
export function toCurl(d: NetRequestDetail): string {
  const method = (d.method || 'GET').toUpperCase();
  const body = classifyBody(d.reqBody);
  const comments: string[] = [];
  const segments: string[] = [];

  // Force the verb when it isn't a plain GET, or when a real body would otherwise flip curl to POST.
  const head = method !== 'GET' || body.usable != null ? `curl -X ${method} ` : 'curl ';
  segments.push(head + shq(d.url));

  const stripped: string[] = [];
  if (d.reqHeaders) {
    for (const [k, v] of Object.entries(d.reqHeaders)) {
      if (v === REDACTED) {
        stripped.push(k); // would send the literal "<redacted>" and 401 — drop it instead
        continue;
      }
      segments.push(`-H ${shq(`${k}: ${v}`)}`);
    }
  }
  if (body.usable != null) segments.push(`--data-raw ${shq(body.usable)}`);

  // Leading `#` comment lines paste cleanly above the `\`-continued command.
  if (stripped.length) comments.push(`# headers omitted (redacted by server): ${stripped.join(', ')}`);
  if (body.note) comments.push(`# request body omitted: ${body.note}`);

  const cmd = segments.join(' \\\n  ');
  return comments.length ? `${comments.join('\n')}\n${cmd}` : cmd;
}

function headersArray(h?: Record<string, string>): Array<{ name: string; value: string }> {
  return h ? Object.entries(h).map(([name, value]) => ({ name, value })) : [];
}

function headerValue(h: Record<string, string> | undefined, name: string): string | undefined {
  if (!h) return undefined;
  const lower = name.toLowerCase();
  for (const [k, v] of Object.entries(h)) if (k.toLowerCase() === lower) return v;
  return undefined;
}

function byteLen(s: string | null | undefined): number {
  if (!s) return 0;
  try {
    return new TextEncoder().encode(s).length;
  } catch {
    return s.length;
  }
}

// Match formatClock's heuristic: values below ~1e12 are seconds, otherwise milliseconds.
function toMs(t: number): number {
  return t < 1e12 ? t * 1000 : t;
}

function isoOrEpoch(t: number): string {
  const d = new Date(toMs(t));
  return Number.isNaN(d.getTime()) ? new Date(0).toISOString() : d.toISOString();
}

/** Build a valid HAR 1.2 log containing this single transaction. */
export function toHar(d: NetRequestDetail): string {
  let queryString: Array<{ name: string; value: string }> = [];
  try {
    const u = new URL(d.url);
    queryString = [...u.searchParams.entries()].map(([name, value]) => ({ name, value }));
  } catch {
    /* relative or malformed URL — leave queryString empty */
  }

  const reqMime = headerValue(d.reqHeaders, 'content-type') || 'application/octet-stream';
  const respMime = headerValue(d.respHeaders, 'content-type') || 'application/octet-stream';
  const reqBody = classifyBody(d.reqBody);
  const respBody = classifyBody(d.respBody);
  const wait = d.durationMs ?? 0;

  // Faithful record: keep <redacted> header values as-is, but note them so a HAR reader knows the
  // capture was sanitized; record only real bodies as text (preview placeholders go in `comment`).
  const stripped = redactedNames(d.reqHeaders);
  const reqComment = [
    stripped.length ? `headers redacted by server: ${stripped.join(', ')}` : '',
    reqBody.note ? `request body omitted: ${reqBody.note}` : '',
  ]
    .filter(Boolean)
    .join('; ');

  const entry = {
    startedDateTime: isoOrEpoch(d.startedAt),
    time: wait,
    request: {
      method: (d.method || 'GET').toUpperCase(),
      url: d.url,
      httpVersion: 'HTTP/1.1',
      cookies: [] as unknown[],
      headers: headersArray(d.reqHeaders),
      queryString,
      ...(reqBody.usable != null
        ? { postData: { mimeType: reqMime, text: reqBody.usable, params: [] as unknown[] } }
        : {}),
      headersSize: -1,
      bodySize: d.reqBytes ?? byteLen(reqBody.usable),
      ...(reqComment ? { comment: reqComment } : {}),
    },
    response: {
      status: d.status ?? 0,
      statusText: '',
      httpVersion: 'HTTP/1.1',
      cookies: [] as unknown[],
      headers: headersArray(d.respHeaders),
      content: {
        size: d.respBytes ?? byteLen(respBody.usable),
        mimeType: respMime,
        text: respBody.usable ?? '',
        ...(respBody.note ? { comment: `response body omitted: ${respBody.note}` } : {}),
      },
      redirectURL: headerValue(d.respHeaders, 'location') || '',
      headersSize: -1,
      bodySize: d.respBytes ?? byteLen(respBody.usable),
    },
    cache: {},
    timings: { send: 0, wait, receive: 0 },
  };

  const har = {
    log: {
      version: '1.2',
      creator: { name: 'SandboxServer console', version: '1.0' },
      entries: [entry],
    },
  };

  return JSON.stringify(har, null, 2);
}

/** A filesystem-safe filename stem derived from the request host + path. */
export function harFilename(d: NetRequestDetail): string {
  let stem = 'request';
  try {
    const u = new URL(d.url);
    stem = `${u.host}${u.pathname}`.replace(/[^a-zA-Z0-9._-]+/g, '_').replace(/^_+|_+$/g, '');
  } catch {
    /* keep default */
  }
  return `${stem || 'request'}.har`;
}
