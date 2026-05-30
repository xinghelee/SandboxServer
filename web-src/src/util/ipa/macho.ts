// Dependency-free Mach-O reader — the TS twin of Sources/.../BundlePlugin/MachOInspector.swift.
// Same field names, same detection rules, so the device-side and browser-side analyses agree.
// Operates on an in-memory Uint8Array (the executable extracted from an uploaded IPA), not a file
// handle — IPA executables are bounded by the upload, and we still bounds-check every read.

export interface MachOSlice {
  cpuType: string;
  cpuSubtype: string;
  is64: boolean;
  magic: string;
  encrypted: boolean;
  cryptId: number | null;
  fileType: string | null;
  pie: boolean | null;
  stackCanary: boolean | null;
  arc: boolean | null;
  codeSignature: boolean | null;
  restrict: boolean | null;
}

export interface MachOInfo {
  supported: boolean;
  executablePath?: string;
  fileSize: number;
  fat: boolean;
  slices: MachOSlice[];
}

const FAT_MAGIC = 0xcafebabe;
const FAT_MAGIC_64 = 0xcafebabf;
const MH_MAGIC = 0xfeedface;
const MH_MAGIC_64 = 0xfeedfacf;
const MH_CIGAM = 0xcefaedfe;
const MH_CIGAM_64 = 0xcffaedfe;
const LC_ENCRYPTION_INFO = 0x21;
const LC_ENCRYPTION_INFO_64 = 0x2c;
const LC_SYMTAB = 0x2;
const LC_CODE_SIGNATURE = 0x1d;
const LC_SEGMENT = 0x1;
const LC_SEGMENT_64 = 0x19;
const MH_PIE = 0x00200000;
const CPU_ARCH_ABI64 = 0x01000000;
const CPU_SUBTYPE_MASK = 0xff000000;

const MAX_ARCHS = 32;
const MAX_LOAD_COMMANDS = 100_000;
const MAX_STRING_TABLE_SCAN = 16 * 1024 * 1024;

export function inspectMachO(bytes: Uint8Array, path?: string): MachOInfo {
  const fileSize = bytes.byteLength;
  if (fileSize < 4) return empty(path, fileSize);
  const beMagic = u32(bytes, 0, true);
  if (beMagic === null) return empty(path, fileSize);

  if (beMagic === FAT_MAGIC || beMagic === FAT_MAGIC_64) {
    const slices = parseFat(bytes, fileSize, beMagic === FAT_MAGIC_64);
    return { supported: slices.length > 0, executablePath: path, fileSize, fat: true, slices };
  }
  const slice = parseMachO(bytes, 0, fileSize);
  if (slice) return { supported: true, executablePath: path, fileSize, fat: false, slices: [slice] };
  return empty(path, fileSize);
}

function empty(path: string | undefined, fileSize: number): MachOInfo {
  return { supported: false, executablePath: path, fileSize, fat: false, slices: [] };
}

function parseFat(b: Uint8Array, fileSize: number, is64: boolean): MachOSlice[] {
  const nfat = u32(b, 4, true);
  if (nfat === null) return [];
  const count = Math.min(nfat, MAX_ARCHS);
  const archSize = is64 ? 32 : 20;
  const slices: MachOSlice[] = [];
  for (let i = 0; i < count; i++) {
    const e = 8 + i * archSize;
    const cpuType = u32(b, e, true);
    const cpuSub = u32(b, e + 4, true);
    if (cpuType === null || cpuSub === null) break;
    let sliceOffset: number | null;
    if (is64) {
      const hi = u32(b, e + 8, true);
      const lo = u32(b, e + 12, true);
      sliceOffset = hi === null || lo === null ? null : hi * 0x100000000 + lo;
    } else {
      sliceOffset = u32(b, e + 8, true);
    }
    if (sliceOffset === null) break;
    const parsed = sliceOffset > 0 && sliceOffset < fileSize ? parseMachO(b, sliceOffset, fileSize) : null;
    if (parsed) {
      slices.push(parsed);
    } else {
      slices.push({
        cpuType: cpuTypeName(cpuType),
        cpuSubtype: cpuSubtypeName(cpuType, cpuSub),
        is64: (cpuType & CPU_ARCH_ABI64) !== 0,
        magic: '(fat arch)',
        encrypted: false,
        cryptId: null,
        fileType: null,
        pie: null,
        stackCanary: null,
        arc: null,
        codeSignature: null,
        restrict: null,
      });
    }
  }
  return slices;
}

function parseMachO(b: Uint8Array, offset: number, fileSize: number): MachOSlice | null {
  const native = u32(b, offset, false);
  if (native === null) return null;
  let is64: boolean;
  let be: boolean;
  let magicName: string;
  switch (native >>> 0) {
    case MH_MAGIC: is64 = false; be = false; magicName = 'MH_MAGIC'; break;
    case MH_MAGIC_64: is64 = true; be = false; magicName = 'MH_MAGIC_64'; break;
    case MH_CIGAM: is64 = false; be = true; magicName = 'MH_CIGAM'; break;
    case MH_CIGAM_64: is64 = true; be = true; magicName = 'MH_CIGAM_64'; break;
    default: return null;
  }

  const headerSize = is64 ? 32 : 28;
  if (offset + headerSize > fileSize) return null;
  const cpuType = u32(b, offset + 4, be);
  const cpuSubtype = u32(b, offset + 8, be);
  const fileType = u32(b, offset + 12, be);
  const ncmdsRaw = u32(b, offset + 16, be);
  const sizeofcmds = u32(b, offset + 20, be);
  const flags = u32(b, offset + 24, be);
  if (cpuType === null || cpuSubtype === null || fileType === null || ncmdsRaw === null || sizeofcmds === null || flags === null) {
    return null;
  }

  const ncmds = Math.min(ncmdsRaw, MAX_LOAD_COMMANDS);
  const cmdsRegion = Math.min(sizeofcmds, Math.max(0, fileSize - offset - headerSize));
  let cryptId: number | null = null;
  let hasCodeSignature = false;
  let hasRestrict = false;
  let strTab: { off: number; size: number } | null = null;

  if (cmdsRegion >= 8) {
    const base = offset + headerSize;
    let cursor = 0;
    for (let n = 0; n < ncmds; n++) {
      if (cursor + 8 > cmdsRegion) break;
      const cmd = u32(b, base + cursor, be);
      const cmdsize = u32(b, base + cursor + 4, be);
      if (cmd === null || cmdsize === null || cmdsize < 8) break;
      switch (cmd) {
        case LC_ENCRYPTION_INFO:
        case LC_ENCRYPTION_INFO_64:
          if (cursor + 20 <= cmdsRegion) cryptId = u32(b, base + cursor + 16, be);
          break;
        case LC_CODE_SIGNATURE:
          hasCodeSignature = true;
          break;
        case LC_SYMTAB:
          if (cursor + 24 <= cmdsRegion) {
            const stroff = u32(b, base + cursor + 16, be);
            const strsize = u32(b, base + cursor + 20, be);
            if (stroff !== null && strsize !== null) strTab = { off: offset + stroff, size: strsize };
          }
          break;
        case LC_SEGMENT:
        case LC_SEGMENT_64:
          if (segmentName(b, base + cursor) === '__RESTRICT') hasRestrict = true;
          break;
      }
      cursor += cmdsize;
      if (cursor > cmdsRegion) break;
    }
  }

  let stackCanary: boolean | null = null;
  let arc: boolean | null = null;
  if (strTab && strTab.size > 0) {
    const scan = Math.min(strTab.size, MAX_STRING_TABLE_SCAN);
    if (strTab.off + scan <= fileSize) {
      const blob = b.subarray(strTab.off, strTab.off + scan);
      stackCanary = contains(blob, 'stack_chk');
      arc = contains(blob, '_objc_release');
    }
  }

  return {
    cpuType: cpuTypeName(cpuType),
    cpuSubtype: cpuSubtypeName(cpuType, cpuSubtype),
    is64,
    magic: magicName,
    encrypted: (cryptId ?? 0) !== 0,
    cryptId,
    fileType: fileTypeName(fileType),
    pie: (flags & MH_PIE) !== 0,
    stackCanary,
    arc,
    codeSignature: hasCodeSignature,
    restrict: hasRestrict,
  };
}

function segmentName(b: Uint8Array, cmdStart: number): string | null {
  const start = cmdStart + 8;
  if (start + 16 > b.byteLength) return null;
  let s = '';
  for (let i = 0; i < 16; i++) {
    const c = b[start + i] ?? 0;
    if (c === 0) break;
    s += String.fromCharCode(c);
  }
  return s;
}

function contains(haystack: Uint8Array, needleStr: string): boolean {
  const needle = needleStr;
  const nlen = needle.length;
  if (nlen === 0 || haystack.length < nlen) return false;
  const first = needle.charCodeAt(0);
  const last = haystack.length - nlen;
  for (let i = 0; i <= last; i++) {
    if (haystack[i] === first) {
      let j = 1;
      while (j < nlen && haystack[i + j] === needle.charCodeAt(j)) j++;
      if (j === nlen) return true;
    }
  }
  return false;
}

function cpuTypeName(t: number): string {
  switch (t >>> 0) {
    case 0x0100000c: return 'arm64';
    case 0x0200000c: return 'arm64_32';
    case 0x0000000c: return 'arm';
    case 0x01000007: return 'x86_64';
    case 0x00000007: return 'i386';
    default: return `cputype(${t})`;
  }
}

function cpuSubtypeName(type: number, sub: number): string {
  const s = (sub & ~CPU_SUBTYPE_MASK) >>> 0;
  if ((type >>> 0) === 0x0100000c) {
    return s === 0 ? 'arm64' : s === 1 ? 'arm64v8' : s === 2 ? 'arm64e' : `arm64(${s})`;
  }
  if ((type >>> 0) === 0x0000000c) {
    return s === 9 ? 'armv7' : s === 11 ? 'armv7s' : s === 12 ? 'armv7k' : `arm(${s})`;
  }
  if ((type >>> 0) === 0x01000007) return 'x86_64';
  return `subtype(${s})`;
}

function fileTypeName(t: number): string | null {
  switch (t) {
    case 2: return 'execute';
    case 6: return 'dylib';
    case 8: return 'bundle';
    default: return `filetype(${t})`;
  }
}

/** Read a uint32, or null if out of bounds. Big- or little-endian, assembled byte-wise. */
function u32(b: Uint8Array, off: number, bigEndian: boolean): number | null {
  if (off < 0 || off + 4 > b.byteLength) return null;
  const b0 = b[off]!;
  const b1 = b[off + 1]!;
  const b2 = b[off + 2]!;
  const b3 = b[off + 3]!;
  return bigEndian
    ? ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3) >>> 0
    : ((b3 << 24) | (b2 << 16) | (b1 << 8) | b0) >>> 0;
}
