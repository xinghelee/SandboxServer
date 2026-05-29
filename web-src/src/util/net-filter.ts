import type { NetRequestSummary } from '../api/types';

// A small Chrome-DevTools-style query language for the network filter:
//   - space-separated terms are AND-ed (all must match)
//   - a leading `-` negates a term (exclude rows that match it)
//   - `field:value` scopes a term to one field: method | status | host | url
//       · status:404  exact code        · status:4xx  status class
//       · method:post                    · host:api.example.com   · url:/v1/users
//   - a bare term matches across method + url + status
// Everything is case-insensitive. Example:  `api -healthz status:4xx`

type Field = 'any' | 'method' | 'status' | 'host' | 'url';
interface Term {
  field: Field;
  value: string;
  negate: boolean;
}
export interface NetQuery {
  terms: Term[];
}

const SCOPES: Record<string, Field> = {
  method: 'method',
  status: 'status',
  host: 'host',
  url: 'url',
};

export function parseNetQuery(input: string): NetQuery {
  const terms: Term[] = [];
  for (const raw of input.trim().toLowerCase().split(/\s+/)) {
    if (!raw) continue;
    let tok = raw;
    let negate = false;
    if (tok.length > 1 && tok.startsWith('-')) {
      negate = true;
      tok = tok.slice(1);
    }
    const colon = tok.indexOf(':');
    if (colon > 0) {
      const scope = SCOPES[tok.slice(0, colon)];
      const value = tok.slice(colon + 1);
      if (scope && value) {
        terms.push({ field: scope, value, negate });
        continue;
      }
    }
    terms.push({ field: 'any', value: tok, negate });
  }
  return { terms };
}

/** True if the query has any meaningful terms (used to decide whether to show "matched / total"). */
export function hasQuery(q: NetQuery): boolean {
  return q.terms.length > 0;
}

function hostOf(url: string): string {
  try {
    return new URL(url).host.toLowerCase();
  } catch {
    return url.toLowerCase();
  }
}

function termMatches(t: Term, r: NetRequestSummary): boolean {
  const status = r.status == null ? '' : String(r.status);
  const method = (r.method || '').toLowerCase();
  const url = (r.url || '').toLowerCase();
  switch (t.field) {
    case 'method':
      return method === t.value || method.startsWith(t.value);
    case 'status':
      if (/^\dxx$/.test(t.value)) {
        return r.status != null && Math.floor(r.status / 100) === Number(t.value.charAt(0));
      }
      return status.includes(t.value);
    case 'host':
      return hostOf(r.url).includes(t.value);
    case 'url':
      return url.includes(t.value);
    default:
      return method.includes(t.value) || url.includes(t.value) || status.includes(t.value);
  }
}

export function matchesNetQuery(r: NetRequestSummary, q: NetQuery): boolean {
  for (const t of q.terms) {
    const m = termMatches(t, r);
    if (t.negate && m) return false; // excluded
    if (!t.negate && !m) return false; // a required term is missing
  }
  return true;
}
