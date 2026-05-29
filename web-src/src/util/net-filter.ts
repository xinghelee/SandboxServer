import type { NetRequestSummary } from '../api/types';

// A Chrome/Proxyman-style query language for the network filter, evaluated over the request
// *summary* (no body). Grammar:
//   - space-separated terms are AND-ed; `OR` (uppercase) splits into OR-ed groups
//       `api status:5xx OR -healthz`  →  (api AND status:5xx) OR (NOT healthz)
//   - a leading `-` negates a term (exclude rows it matches)
//   - `field:value` scopes a term: method | status | host | url
//       status:404 (exact) · status:4xx (class) · method:post · host:api · url:/v1/users
//   - `/pattern/flags` is a regex (scopeable: url:/v\d+/i); invalid regex falls back to literal
//   - numeric comparisons on status | dur (ms) | size (resp bytes) | reqsize (req bytes):
//       status>=400 · dur>500 · size<1000 · reqsize<=512   (ops: = > < >= <=)
// Literal matching is case-insensitive; regex case follows its flags.

type Field = 'any' | 'method' | 'status' | 'host' | 'url';
type NumField = 'status' | 'dur' | 'size' | 'reqsize';
type CmpOp = '=' | '>' | '<' | '>=' | '<=';

interface LiteralTerm {
  kind: 'literal';
  field: Field;
  value: string; // already lower-cased
  negate: boolean;
}
interface RegexTerm {
  kind: 'regex';
  field: Field;
  re: RegExp;
  negate: boolean;
}
interface NumericTerm {
  kind: 'numeric';
  field: NumField;
  op: CmpOp;
  n: number;
  negate: boolean;
}
type Term = LiteralTerm | RegexTerm | NumericTerm;

/** OR of AND-groups: matches if ANY group fully matches. */
export interface NetQuery {
  groups: Term[][];
}

const SCOPES: Record<string, Field> = { method: 'method', status: 'status', host: 'host', url: 'url' };
const NUM_FIELDS: Record<string, NumField> = { status: 'status', dur: 'dur', size: 'size', reqsize: 'reqsize' };
const NUMERIC_RE = /^(status|dur|size|reqsize)(>=|<=|=|>|<)(\d+)$/i;

function parseRegexLiteral(s: string): RegExp | null {
  if (s.length < 2 || s.charAt(0) !== '/') return null;
  const last = s.lastIndexOf('/');
  if (last <= 0) return null;
  const flags = s.slice(last + 1);
  if (!/^[imsu]*$/.test(flags)) return null;
  try {
    return new RegExp(s.slice(1, last), flags);
  } catch {
    return null; // invalid pattern — caller falls back to a literal match
  }
}

function parseTerm(tok: string): Term | null {
  let negate = false;
  let s = tok;
  if (s.length > 1 && s.startsWith('-')) {
    negate = true;
    s = s.slice(1);
  }

  const num = NUMERIC_RE.exec(s);
  if (num) {
    const field = NUM_FIELDS[(num[1] ?? '').toLowerCase()];
    const op = num[2] as CmpOp;
    const n = Number(num[3]);
    if (field) return { kind: 'numeric', field, op, n, negate };
  }

  const colon = s.indexOf(':');
  if (colon > 0) {
    const scope = SCOPES[s.slice(0, colon).toLowerCase()];
    const rest = s.slice(colon + 1);
    if (scope && rest) {
      const re = parseRegexLiteral(rest);
      return re
        ? { kind: 'regex', field: scope, re, negate }
        : { kind: 'literal', field: scope, value: rest.toLowerCase(), negate };
    }
  }

  const re = parseRegexLiteral(s);
  if (re) return { kind: 'regex', field: 'any', re, negate };

  if (!s) return null;
  return { kind: 'literal', field: 'any', value: s.toLowerCase(), negate };
}

export function parseNetQuery(input: string): NetQuery {
  const groups: Term[][] = [];
  let current: Term[] = [];
  for (const tok of input.trim().split(/\s+/)) {
    if (!tok) continue;
    if (tok === 'OR') {
      groups.push(current);
      current = [];
      continue;
    }
    const t = parseTerm(tok);
    if (t) current.push(t);
  }
  groups.push(current);
  return { groups: groups.filter((g) => g.length > 0) };
}

export function hasQuery(q: NetQuery): boolean {
  return q.groups.length > 0;
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

function regexText(field: Field, r: NetRequestSummary): string {
  switch (field) {
    case 'method':
      return r.method || '';
    case 'status':
      return r.status == null ? '' : String(r.status);
    case 'host':
      return hostOf(r.url);
    case 'url':
      return r.url || '';
    default:
      return `${r.method || ''} ${r.url || ''} ${r.status ?? ''}`;
  }
}

function literalMatch(t: LiteralTerm, r: NetRequestSummary): boolean {
  const v = t.value;
  switch (t.field) {
    case 'method': {
      const m = (r.method || '').toLowerCase();
      return m === v || m.startsWith(v);
    }
    case 'status':
      if (/^\dxx$/.test(v)) return r.status != null && Math.floor(r.status / 100) === Number(v.charAt(0));
      return String(r.status ?? '').includes(v);
    case 'host':
      return hostOf(r.url).toLowerCase().includes(v);
    case 'url':
      return (r.url || '').toLowerCase().includes(v);
    default:
      return `${r.method || ''} ${r.url || ''} ${r.status ?? ''}`.toLowerCase().includes(v);
  }
}

function numericValue(field: NumField, r: NetRequestSummary): number | null {
  switch (field) {
    case 'status':
      return r.status;
    case 'dur':
      return r.durationMs;
    case 'size':
      return r.respBytes;
    case 'reqsize':
      return r.reqBytes;
  }
}

function compare(a: number, op: CmpOp, b: number): boolean {
  switch (op) {
    case '=':
      return a === b;
    case '>':
      return a > b;
    case '<':
      return a < b;
    case '>=':
      return a >= b;
    case '<=':
      return a <= b;
  }
}

function termMatches(t: Term, r: NetRequestSummary): boolean {
  switch (t.kind) {
    case 'literal':
      return literalMatch(t, r);
    case 'regex':
      return t.re.test(regexText(t.field, r));
    case 'numeric': {
      const v = numericValue(t.field, r);
      return v != null && compare(v, t.op, t.n); // null (pending / unknown) never matches a comparison
    }
  }
}

export function matchesNetQuery(r: NetRequestSummary, q: NetQuery): boolean {
  if (q.groups.length === 0) return true;
  return q.groups.some((group) =>
    group.every((t) => {
      const m = termMatches(t, r);
      return t.negate ? !m : m;
    }),
  );
}
