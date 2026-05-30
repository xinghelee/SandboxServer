// Binary property list (bplist00) parser → JS value. Covers the subset Info.plist and provisioning
// entitlements use: bool, int, real, date, data, ASCII/UTF-16 strings, arrays, dicts. Dates and Data
// are tagged ({$date}/{$data}) to match the device's plist→JSON convention so both render identically.

export type PlistValue =
  | null
  | boolean
  | number
  | string
  | { $date: number } // unix seconds
  | { $data: string; bytes: number } // base64 + length
  | PlistValue[]
  | { [key: string]: PlistValue };

const MAGIC = 'bplist00';
const APPLE_EPOCH = 978_307_200; // seconds between 1970-01-01 and 2001-01-01

export function isBinaryPlist(bytes: Uint8Array): boolean {
  if (bytes.length < 8) return false;
  for (let i = 0; i < 8; i++) {
    if (bytes[i] !== MAGIC.charCodeAt(i)) return false;
  }
  return true;
}

/** Parse a binary plist. Throws on a malformed/non-binary buffer. */
export function parseBinaryPlist(bytes: Uint8Array): PlistValue {
  if (!isBinaryPlist(bytes)) throw new Error('not a binary plist');
  if (bytes.length < 8 + 32) throw new Error('binary plist too short');

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const trailer = bytes.byteLength - 32;
  const offsetSize = bytes[trailer + 6] ?? 0;
  const refSize = bytes[trailer + 7] ?? 0;
  const numObjects = readUInt(view, trailer + 8, 8);
  const topObject = readUInt(view, trailer + 16, 8);
  const offsetTableOffset = readUInt(view, trailer + 24, 8);
  if (offsetSize < 1 || refSize < 1 || numObjects < 1) throw new Error('bad binary plist trailer');
  if (offsetTableOffset + numObjects * offsetSize > bytes.byteLength) throw new Error('bad offset table');

  const offsets: number[] = [];
  for (let i = 0; i < numObjects; i++) {
    offsets.push(readUInt(view, offsetTableOffset + i * offsetSize, offsetSize));
  }

  // Recursive reader by object index, guarding cycles and depth.
  const seen = new Set<number>();
  const read = (index: number, depth: number): PlistValue => {
    if (depth > 64) throw new Error('binary plist too deeply nested');
    if (index >= offsets.length) throw new Error('object ref out of range');
    const pos = offsets[index];
    if (pos === undefined || pos >= bytes.byteLength) throw new Error('object offset out of range');
    const marker = bytes[pos] ?? 0;
    const type = marker & 0xf0;
    const info = marker & 0x0f;

    switch (type) {
      case 0x00:
        if (info === 0x00) return null;
        if (info === 0x08) return false;
        if (info === 0x09) return true;
        return null;
      case 0x10: {
        // int: 2^info bytes, big-endian.
        const len = 1 << info;
        return readUInt(view, pos + 1, len);
      }
      case 0x20: {
        // real: 4 or 8 bytes float, big-endian.
        const len = 1 << info;
        return len === 8 ? view.getFloat64(pos + 1, false) : view.getFloat32(pos + 1, false);
      }
      case 0x30:
        // date: float64 seconds since 2001.
        return { $date: Math.round(view.getFloat64(pos + 1, false) + APPLE_EPOCH) };
      case 0x40: {
        // data
        const [len, dataStart] = readLength(bytes, view, pos, info);
        const slice = bytes.subarray(dataStart, dataStart + len);
        return { $data: bytesToBase64(slice), bytes: len };
      }
      case 0x50: {
        // ASCII string
        const [len, strStart] = readLength(bytes, view, pos, info);
        return asciiString(bytes, strStart, len);
      }
      case 0x60: {
        // UTF-16BE string (length is in code units)
        const [len, strStart] = readLength(bytes, view, pos, info);
        return utf16beString(view, strStart, len);
      }
      case 0x80: {
        // uid: info+1 bytes — surface as a number (rare in our inputs)
        return readUInt(view, pos + 1, info + 1);
      }
      case 0xa0: {
        // array
        const [count, refStart] = readLength(bytes, view, pos, info);
        if (seen.has(index)) throw new Error('cyclic binary plist');
        seen.add(index);
        const arr: PlistValue[] = [];
        for (let i = 0; i < count; i++) {
          arr.push(read(readUInt(view, refStart + i * refSize, refSize), depth + 1));
        }
        seen.delete(index);
        return arr;
      }
      case 0xd0: {
        // dict: count key-refs, then count value-refs
        const [count, keyStart] = readLength(bytes, view, pos, info);
        if (seen.has(index)) throw new Error('cyclic binary plist');
        seen.add(index);
        const valStart = keyStart + count * refSize;
        const obj: { [key: string]: PlistValue } = {};
        for (let i = 0; i < count; i++) {
          const key = read(readUInt(view, keyStart + i * refSize, refSize), depth + 1);
          const val = read(readUInt(view, valStart + i * refSize, refSize), depth + 1);
          obj[typeof key === 'string' ? key : String(key)] = val;
        }
        seen.delete(index);
        return obj;
      }
      default:
        throw new Error(`unsupported binary plist marker 0x${marker.toString(16)}`);
    }
  };

  return read(topObject, 0);
}

// --- helpers ---

/** A collection/string/data length: the low nibble, or an extended int object when nibble == 0x0F.
 *  Returns [count, dataStart] where dataStart is the byte after the marker (+ extended-int bytes). */
function readLength(bytes: Uint8Array, view: DataView, pos: number, info: number): [number, number] {
  if (info !== 0x0f) return [info, pos + 1];
  const intMarker = bytes[pos + 1] ?? 0;
  if ((intMarker & 0xf0) !== 0x10) throw new Error('bad extended length');
  const intLen = 1 << (intMarker & 0x0f);
  const count = readUInt(view, pos + 2, intLen);
  return [count, pos + 2 + intLen];
}

function readUInt(view: DataView, offset: number, size: number): number {
  let value = 0;
  for (let i = 0; i < size; i++) {
    value = value * 256 + view.getUint8(offset + i);
  }
  return value;
}

function asciiString(bytes: Uint8Array, start: number, len: number): string {
  let s = '';
  for (let i = 0; i < len; i++) s += String.fromCharCode(bytes[start + i] ?? 0);
  return s;
}

function utf16beString(view: DataView, start: number, units: number): string {
  let s = '';
  for (let i = 0; i < units; i++) s += String.fromCharCode(view.getUint16(start + i * 2, false));
  return s;
}

function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}
