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

// --- Visual builder ⇄ query string ---
// The builder is a thin UI layer that compiles to the query string above (the single source of
// truth). v1 reverse-parses only the simple AND case; OR / nested queries start the builder fresh.

export type BuilderField = 'any' | 'method' | 'status' | 'host' | 'url' | 'dur' | 'size';
export interface BuilderRow {
  field: BuilderField;
  op: string; // contains | is | matches | > | < | >= | <= | =
  value: string;
  negate: boolean;
}

export function blankRow(): BuilderRow {
  return { field: 'any', op: 'contains', value: '', negate: false };
}

function compileRow(r: BuilderRow): string {
  const v = r.value.trim();
  if (!v) return '';
  const neg = r.negate ? '-' : '';
  switch (r.field) {
    case 'any':
      return neg + v;
    case 'method':
      return `${neg}method:${v}`;
    case 'host':
      return `${neg}host:${v}`;
    case 'url':
      return r.op === 'matches' ? `${neg}url:/${v}/` : `${neg}url:${v}`;
    case 'status':
      return r.op === 'is' ? `${neg}status:${v}` : `${neg}status${r.op}${v}`;
    case 'dur':
      return `${neg}dur${r.op}${v}`;
    case 'size':
      return `${neg}size${r.op}${v}`;
  }
}

/** Compile builder rows to a query string. `matchAny` joins with OR (else AND / space). */
export function compileBuilder(rows: BuilderRow[], matchAny: boolean): string {
  const toks = rows.map(compileRow).filter((t) => t.length > 0);
  return toks.join(matchAny ? ' OR ' : ' ');
}

/** Best-effort reverse: turn a simple AND query into rows. Returns null if it can't (OR / empty). */
export function rowsFromQuery(input: string): BuilderRow[] | null {
  const trimmed = input.trim();
  if (!trimmed || / OR /.test(trimmed)) return null;
  const rows: BuilderRow[] = [];
  for (const tok of trimmed.split(/\s+/)) {
    let s = tok;
    let negate = false;
    if (s.length > 1 && s.startsWith('-')) {
      negate = true;
      s = s.slice(1);
    }
    const num = /^(status|dur|size)(>=|<=|=|>|<)(\d+)$/.exec(s);
    if (num) {
      rows.push({ field: num[1] as BuilderField, op: num[2] ?? '>', value: num[3] ?? '', negate });
      continue;
    }
    const colon = s.indexOf(':');
    if (colon > 0) {
      const f = s.slice(0, colon);
      const rest = s.slice(colon + 1);
      if ((f === 'method' || f === 'host' || f === 'url' || f === 'status') && rest) {
        if (f === 'url' && rest.length > 1 && rest.startsWith('/') && rest.endsWith('/')) {
          rows.push({ field: 'url', op: 'matches', value: rest.slice(1, -1), negate });
        } else {
          rows.push({ field: f, op: f === 'method' || f === 'status' ? 'is' : 'contains', value: rest, negate });
        }
        continue;
      }
    }
    rows.push({ field: 'any', op: 'contains', value: s, negate });
  }
  return rows.length ? rows : null;
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
