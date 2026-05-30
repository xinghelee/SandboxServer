// Minimal ZIP reader — dependency-free. Reads the central directory, then extracts only the entries
// we ask for (the app's Info.plist + Mach-O executable), so we never inflate the whole IPA. DEFLATE
// is handled by the browser-native DecompressionStream('deflate-raw') (no JS inflate dependency).
//
// We deliberately do NOT support: zip64, encryption, or data descriptors without a usable central
// directory. Real IPAs are plain stored/deflated zips, so this covers them.

export interface ZipEntry {
  name: string;
  compressedSize: number;
  uncompressedSize: number;
  compressionMethod: number; // 0 = stored, 8 = deflate
  localHeaderOffset: number;
}

const EOCD_SIG = 0x06054b50; // End Of Central Directory
const CEN_SIG = 0x02014b50; // Central directory file header
const LOC_SIG = 0x04034b50; // Local file header

/** Read the central directory. Throws if the buffer isn't a usable zip. */
export function readCentralDirectory(buf: Uint8Array): ZipEntry[] {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const eocd = findEOCD(view, buf.byteLength);
  if (eocd < 0) throw new Error('not a zip (no end-of-central-directory record)');

  const entryCount = view.getUint16(eocd + 10, true);
  let ptr = view.getUint32(eocd + 16, true); // central directory offset
  const entries: ZipEntry[] = [];

  for (let i = 0; i < entryCount; i++) {
    if (ptr + 46 > buf.byteLength || view.getUint32(ptr, true) !== CEN_SIG) break;
    const compressionMethod = view.getUint16(ptr + 10, true);
    const compressedSize = view.getUint32(ptr + 20, true);
    const uncompressedSize = view.getUint32(ptr + 24, true);
    const nameLen = view.getUint16(ptr + 28, true);
    const extraLen = view.getUint16(ptr + 30, true);
    const commentLen = view.getUint16(ptr + 32, true);
    const localHeaderOffset = view.getUint32(ptr + 42, true);
    const name = utf8(buf, ptr + 46, nameLen);
    entries.push({ name, compressedSize, uncompressedSize, compressionMethod, localHeaderOffset });
    ptr += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

/** Extract one entry's bytes (the local header's own name/extra lengths are authoritative). */
export async function extractEntry(buf: Uint8Array, entry: ZipEntry): Promise<Uint8Array> {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const lh = entry.localHeaderOffset;
  if (lh + 30 > buf.byteLength || view.getUint32(lh, true) !== LOC_SIG) {
    throw new Error(`bad local header for ${entry.name}`);
  }
  const nameLen = view.getUint16(lh + 26, true);
  const extraLen = view.getUint16(lh + 28, true);
  const dataStart = lh + 30 + nameLen + extraLen;
  const compressed = buf.subarray(dataStart, dataStart + entry.compressedSize);

  if (entry.compressionMethod === 0) return compressed.slice(); // stored
  if (entry.compressionMethod === 8) return inflateRaw(compressed); // deflate
  throw new Error(`unsupported compression method ${entry.compressionMethod} for ${entry.name}`);
}

/** Raw-DEFLATE inflate via the browser-native DecompressionStream (no JS dependency). */
async function inflateRaw(data: Uint8Array): Promise<Uint8Array> {
  // `data` is a subarray view; copy to a standalone buffer so Response/stream sees exactly it.
  const body = new Response(data.slice()).body;
  if (!body) throw new Error('cannot read entry stream');
  const stream = body.pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** Scan backwards for the EOCD signature (the record is near the end, after any trailing comment). */
function findEOCD(view: DataView, length: number): number {
  const minPos = Math.max(0, length - 22 - 0xffff); // 22-byte record + max 64K comment
  for (let p = length - 22; p >= minPos; p--) {
    if (view.getUint32(p, true) === EOCD_SIG) return p;
  }
  return -1;
}

function utf8(buf: Uint8Array, start: number, len: number): string {
  return new TextDecoder('utf-8').decode(buf.subarray(start, start + len));
}
