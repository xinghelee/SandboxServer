import Foundation

/// Hand-rolled, dependency-free Mach-O reader. Reports the CPU slices of an executable and, per
/// slice, whether the binary is FairPlay-encrypted (LC_ENCRYPTION_INFO[_64] cryptid != 0).
///
/// Reads ONLY the header + load-command region (never the whole file — executables can be huge),
/// bounds-checks every access against the file size, and caps loop counts so a malformed/hostile
/// binary can't spin or read out of bounds. Integers are assembled from raw bytes (no `load(as:)`
/// — that would be unaligned UB on arm64, and `loadUnaligned` is iOS 15+ while we target iOS 14).
enum MachOInspector {
    struct Slice: Encodable, Sendable {
        let cpuType: String
        let cpuSubtype: String
        let is64: Bool
        let magic: String
        let encrypted: Bool
        let cryptId: Int?      // nil when no encryption load command is present
        let fileType: String?
        // Hardening facts (nil = could not determine, e.g. a fat stub with no slice body).
        let pie: Bool?           // MH_PIE — position-independent → ASLR
        let stackCanary: Bool?   // a `stack_chk` symbol is present
        let arc: Bool?           // an `_objc_release` symbol is present (Automatic Reference Counting)
        let codeSignature: Bool? // an LC_CODE_SIGNATURE load command is present
        let restrict: Bool?      // a `__RESTRICT` segment is present (anti-debug)
    }

    struct Info: Encodable, Sendable {
        let supported: Bool
        let executablePath: String?
        let fileSize: Int
        let fat: Bool
        let slices: [Slice]
    }

    // Magic numbers. Fat headers are stored big-endian on disk; Mach-O magic encodes the slice's
    // own byte order (…CIGAM… = byte-swapped relative to the host).
    private static let FAT_MAGIC: UInt32 = 0xCAFE_BABE
    private static let FAT_MAGIC_64: UInt32 = 0xCAFE_BABF
    private static let MH_MAGIC: UInt32 = 0xFEED_FACE
    private static let MH_MAGIC_64: UInt32 = 0xFEED_FACF
    private static let MH_CIGAM: UInt32 = 0xCEFA_EDFE
    private static let MH_CIGAM_64: UInt32 = 0xCFFA_EDFE
    private static let LC_ENCRYPTION_INFO: UInt32 = 0x21
    private static let LC_ENCRYPTION_INFO_64: UInt32 = 0x2C
    private static let LC_SYMTAB: UInt32 = 0x2
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1D
    private static let LC_SEGMENT: UInt32 = 0x1
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let MH_PIE: UInt32 = 0x0020_0000  // mach_header.flags bit: position-independent

    private static let maxArchs = 32        // a fat binary never has more; caps a hostile nfat_arch
    private static let maxLoadCommands = 100_000
    private static let maxStringTableScan = 16 * 1024 * 1024  // cap the symbol-string read for huge apps

    static func inspect(_ url: URL?) -> Info {
        guard let url else {
            return Info(supported: false, executablePath: nil, fileSize: 0, fat: false, slices: [])
        }
        let fm = FileManager.default
        let fileSize = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Info(supported: false, executablePath: url.path, fileSize: fileSize, fat: false, slices: [])
        }
        defer { try? handle.close() }

        guard let head = bytes(handle, at: 0, 4), let beMagic = u32(head, 0, bigEndian: true) else {
            return Info(supported: false, executablePath: url.path, fileSize: fileSize, fat: false, slices: [])
        }

        if beMagic == FAT_MAGIC || beMagic == FAT_MAGIC_64 {
            let is64Fat = (beMagic == FAT_MAGIC_64)
            let slices = parseFat(handle, fileSize: fileSize, is64: is64Fat)
            return Info(supported: !slices.isEmpty, executablePath: url.path,
                        fileSize: fileSize, fat: true, slices: slices)
        }
        // Thin: the magic at offset 0 is a Mach-O header magic.
        if let slice = parseMachO(handle, at: 0, fileSize: fileSize) {
            return Info(supported: true, executablePath: url.path, fileSize: fileSize, fat: false, slices: [slice])
        }
        return Info(supported: false, executablePath: url.path, fileSize: fileSize, fat: false, slices: [])
    }

    // MARK: - Fat container

    private static func parseFat(_ h: FileHandle, fileSize: Int, is64: Bool) -> [Slice] {
        guard let nfatBytes = bytes(h, at: 4, 4), let nfat = u32(nfatBytes, 0, bigEndian: true) else { return [] }
        let count = min(Int(nfat), maxArchs)
        let archSize = is64 ? 32 : 20   // fat_arch / fat_arch_64
        var slices: [Slice] = []
        for i in 0..<count {
            let entryOffset = UInt64(8 + i * archSize)
            // fat_arch{ cputype:i32@0; cpusubtype:i32@4; offset@8; size; align } — offset/size widen in _64.
            guard let e = bytes(h, at: entryOffset, archSize),
                  let cpuType = u32(e, 0, bigEndian: true),
                  let cpuSub = u32(e, 4, bigEndian: true) else { break }
            let sliceOffset: UInt64
            if is64 {
                guard let off = u64(e, 8, bigEndian: true) else { break }
                sliceOffset = off
            } else {
                guard let off = u32(e, 8, bigEndian: true) else { break }
                sliceOffset = UInt64(off)
            }
            // When the slice body is present, parse its Mach-O header (richer: magic, encryption,
            // file type). When it isn't (a thinned stub, or an out-of-bounds offset), still report
            // the architecture the fat header declares — encryption is then simply unknown.
            if sliceOffset > 0, sliceOffset < UInt64(fileSize),
               let slice = parseMachO(h, at: sliceOffset, fileSize: fileSize) {
                slices.append(slice)
            } else {
                slices.append(Slice(
                    cpuType: cpuTypeName(cpuType),
                    cpuSubtype: cpuSubtypeName(cpuType, cpuSub),
                    is64: (cpuType & CPU_ARCH_ABI64) != 0,
                    magic: "(fat arch)",
                    encrypted: false,
                    cryptId: nil,
                    fileType: nil,
                    pie: nil, stackCanary: nil, arc: nil, codeSignature: nil, restrict: nil
                ))
            }
        }
        return slices
    }

    // MARK: - One Mach-O slice

    private static func parseMachO(_ h: FileHandle, at offset: UInt64, fileSize: Int) -> Slice? {
        guard let m = bytes(h, at: offset, 4), let native = u32(m, 0, bigEndian: false) else { return nil }
        let is64: Bool
        let fieldsBigEndian: Bool
        let magicName: String
        switch native {
        case MH_MAGIC:    is64 = false; fieldsBigEndian = false; magicName = "MH_MAGIC"
        case MH_MAGIC_64: is64 = true;  fieldsBigEndian = false; magicName = "MH_MAGIC_64"
        case MH_CIGAM:    is64 = false; fieldsBigEndian = true;  magicName = "MH_CIGAM"
        case MH_CIGAM_64: is64 = true;  fieldsBigEndian = true;  magicName = "MH_CIGAM_64"
        default: return nil
        }

        let headerSize = is64 ? 32 : 28   // mach_header_64 has a trailing `reserved` word
        guard offset + UInt64(headerSize) <= UInt64(fileSize),
              let hdr = bytes(h, at: offset, headerSize),
              let cpuType = u32(hdr, 4, bigEndian: fieldsBigEndian),
              let cpuSubtype = u32(hdr, 8, bigEndian: fieldsBigEndian),
              let fileType = u32(hdr, 12, bigEndian: fieldsBigEndian),
              let ncmdsRaw = u32(hdr, 16, bigEndian: fieldsBigEndian),
              let sizeofcmds = u32(hdr, 20, bigEndian: fieldsBigEndian),
              let flags = u32(hdr, 24, bigEndian: fieldsBigEndian)
        else { return nil }

        let ncmds = min(Int(ncmdsRaw), maxLoadCommands)
        let cmdsRegion = min(Int(sizeofcmds), max(0, fileSize - Int(offset) - headerSize))
        var cryptId: UInt32?
        var hasCodeSignature = false
        var hasRestrict = false
        var strTab: (off: UInt64, size: Int)?
        if cmdsRegion >= 8, let lc = bytes(h, at: offset + UInt64(headerSize), cmdsRegion) {
            var cursor = 0
            for _ in 0..<ncmds {
                guard cursor + 8 <= lc.count,
                      let cmd = u32(lc, cursor, bigEndian: fieldsBigEndian),
                      let cmdsize = u32(lc, cursor + 4, bigEndian: fieldsBigEndian),
                      cmdsize >= 8 else { break }
                switch cmd {
                case LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64:
                    // encryption_info_command{ cmd@0; cmdsize@4; cryptoff@8; cryptsize@12; cryptid@16 }.
                    if cursor + 20 <= lc.count { cryptId = u32(lc, cursor + 16, bigEndian: fieldsBigEndian) }
                case LC_CODE_SIGNATURE:
                    hasCodeSignature = true
                case LC_SYMTAB:
                    // symtab_command{ cmd@0; cmdsize@4; symoff@8; nsyms@12; stroff@16; strsize@20 }.
                    // stroff is image-relative; absolute file offset adds the slice offset.
                    if cursor + 24 <= lc.count,
                       let stroff = u32(lc, cursor + 16, bigEndian: fieldsBigEndian),
                       let strsize = u32(lc, cursor + 20, bigEndian: fieldsBigEndian) {
                        strTab = (offset + UInt64(stroff), Int(strsize))
                    }
                case LC_SEGMENT, LC_SEGMENT_64:
                    // segment_command{ cmd@0; cmdsize@4; segname[16]@8 }. "__RESTRICT" = anti-debug.
                    if segmentName(lc, at: cursor) == "__RESTRICT" { hasRestrict = true }
                default:
                    break
                }
                cursor += Int(cmdsize)
                if cursor > lc.count { break }
            }
        }

        // Symbol-string scan for stack-canary / ARC markers (bounded; nil if no symbol table).
        var stackCanary: Bool?
        var arc: Bool?
        if let strTab, strTab.size > 0, strTab.off + UInt64(min(strTab.size, maxStringTableScan)) <= UInt64(fileSize),
           let blob = bytes(h, at: strTab.off, min(strTab.size, maxStringTableScan)) {
            stackCanary = contains(blob, Array("stack_chk".utf8))
            arc = contains(blob, Array("_objc_release".utf8))
        }

        return Slice(
            cpuType: cpuTypeName(cpuType),
            cpuSubtype: cpuSubtypeName(cpuType, cpuSubtype),
            is64: is64,
            magic: magicName,
            encrypted: (cryptId ?? 0) != 0,
            cryptId: cryptId.map(Int.init),
            fileType: fileTypeName(fileType),
            pie: (flags & MH_PIE) != 0,
            stackCanary: stackCanary,
            arc: arc,
            codeSignature: hasCodeSignature,
            restrict: hasRestrict
        )
    }

    /// The 16-byte `segname` of a segment load command at `cursor`, trimmed at the first NUL.
    private static func segmentName(_ lc: [UInt8], at cursor: Int) -> String? {
        let start = cursor + 8
        guard start + 16 <= lc.count else { return nil }
        let raw = lc[start..<(start + 16)].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    /// Naive byte-substring search (Boyer-Moore is overkill; the needles are tiny and the haystack
    /// is bounded by `maxStringTableScan`).
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: - Name tables

    private static let CPU_ARCH_ABI64: UInt32 = 0x0100_0000
    private static let CPU_SUBTYPE_MASK: UInt32 = 0xFF00_0000

    private static func cpuTypeName(_ t: UInt32) -> String {
        switch t {
        case 0x0100_000C: return "arm64"
        case 0x0200_000C: return "arm64_32"
        case 0x0000_000C: return "arm"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return "cputype(\(t))"
        }
    }

    private static func cpuSubtypeName(_ type: UInt32, _ sub: UInt32) -> String {
        let s = sub & ~CPU_SUBTYPE_MASK
        if type == 0x0100_000C { // arm64
            switch s { case 0: return "arm64"; case 1: return "arm64v8"; case 2: return "arm64e"; default: return "arm64(\(s))" }
        }
        if type == 0x0000_000C { // arm
            switch s { case 9: return "armv7"; case 11: return "armv7s"; case 12: return "armv7k"; default: return "arm(\(s))" }
        }
        if type == 0x0100_0007 { return "x86_64" }
        return "subtype(\(s))"
    }

    private static func fileTypeName(_ t: UInt32) -> String? {
        switch t {
        case 2: return "execute"
        case 6: return "dylib"
        case 8: return "bundle"
        default: return "filetype(\(t))"
        }
    }

    // MARK: - Bounded byte reads

    /// Reads exactly `count` bytes at `offset`, or nil if the file is too short / the read fails.
    private static func bytes(_ h: FileHandle, at offset: UInt64, _ count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        do {
            try h.seek(toOffset: offset)
            guard let data = try h.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        } catch { return nil }
    }

    private static func u32(_ b: [UInt8], _ off: Int, bigEndian: Bool) -> UInt32? {
        guard off >= 0, off + 4 <= b.count else { return nil }
        let (b0, b1, b2, b3) = (UInt32(b[off]), UInt32(b[off + 1]), UInt32(b[off + 2]), UInt32(b[off + 3]))
        return bigEndian ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
    }

    private static func u64(_ b: [UInt8], _ off: Int, bigEndian: Bool) -> UInt64? {
        guard off >= 0, off + 8 <= b.count else { return nil }
        var value: UInt64 = 0
        if bigEndian {
            for i in 0..<8 { value = (value << 8) | UInt64(b[off + i]) }
        } else {
            for i in (0..<8).reversed() { value = (value << 8) | UInt64(b[off + i]) }
        }
        return value
    }
}
