// Plist dispatcher: binary (bplist00) → our parser; XML → the browser-native DOMParser (zero dep).
// Returns the same tagged shape as the device's plist→JSON ({$date}/{$data}), so values render alike.

import { isBinaryPlist, parseBinaryPlist, type PlistValue } from './bplist';

export type { PlistValue } from './bplist';

/** Parse a plist (binary or XML) from raw bytes. Throws if neither form is recognized. */
export function parsePlist(bytes: Uint8Array): PlistValue {
  if (isBinaryPlist(bytes)) return parseBinaryPlist(bytes);
  const text = new TextDecoder('utf-8').decode(bytes);
  if (text.includes('<plist') || text.includes('<?xml')) return parseXmlPlist(text);
  throw new Error('not a plist (neither bplist00 nor XML)');
}

function parseXmlPlist(text: string): PlistValue {
  const doc = new DOMParser().parseFromString(text, 'application/xml');
  if (doc.querySelector('parsererror')) throw new Error('malformed XML plist');
  const root = doc.querySelector('plist > *');
  if (!root) throw new Error('empty plist');
  return parseNode(root, 0);
}

function parseNode(el: Element, depth: number): PlistValue {
  if (depth > 64) throw new Error('XML plist too deeply nested');
  switch (el.tagName) {
    case 'true':
      return true;
    case 'false':
      return false;
    case 'string':
      return el.textContent ?? '';
    case 'integer':
      return parseInt(el.textContent ?? '0', 10) || 0;
    case 'real':
      return parseFloat(el.textContent ?? '0') || 0;
    case 'date': {
      const ms = Date.parse(el.textContent ?? '');
      return { $date: Number.isNaN(ms) ? 0 : Math.round(ms / 1000) };
    }
    case 'data': {
      const b64 = (el.textContent ?? '').replace(/\s+/g, '');
      let bytes = 0;
      try {
        bytes = atob(b64).length;
      } catch {
        bytes = 0;
      }
      return { $data: b64, bytes };
    }
    case 'array': {
      const out: PlistValue[] = [];
      for (const child of Array.from(el.children)) out.push(parseNode(child, depth + 1));
      return out;
    }
    case 'dict': {
      const obj: { [key: string]: PlistValue } = {};
      const children = Array.from(el.children);
      for (let i = 0; i + 1 < children.length; i += 2) {
        const keyEl = children[i];
        const valEl = children[i + 1];
        if (keyEl && valEl && keyEl.tagName === 'key') {
          obj[keyEl.textContent ?? ''] = parseNode(valEl, depth + 1);
        }
      }
      return obj;
    }
    default:
      return null;
  }
}
