import Foundation
import Compression

/// Display-only, key-free body transforms the network plugin tries when no host
/// ``SandboxConfig/networkBodyDecoder`` claims a body. **Strictly magic-byte gated** so it never
/// touches ordinary JSON/text, and a wrong guess self-corrects (a failed inflate or non-UTF-8
/// result returns nil and falls back to the built-in rendering).
///
/// Currently: gzip (RFC 1952) and zlib (RFC 1950) decompression via the system `Compression`
/// framework (zero third-party dependency). base64 is deliberately NOT auto-applied — ordinary
/// text is indistinguishable from base64, so guessing would corrupt legitimate bodies; that case
/// belongs to a host-provided ``NetworkBodyDecoder``.
enum KeylessBodyDecoder {
    /// Cap on decompressed bytes we materialize — a preview only needs a prefix, and this bounds
    /// memory against a decompression bomb.
    private static let outputCap = 256 * 1024

    /// Returns readable UTF-8 text if `data` is a recognizably-compressed blob that inflates to
    /// valid UTF-8, else nil (caller falls back to the built-in text/binary rendering).
    static func decode(_ data: Data) -> String? {
        guard let deflate = rawDeflatePayload(of: data) else { return nil }
        guard let inflated = inflate(deflate) else { return nil }
        guard let text = String(data: inflated.data, encoding: .utf8) else { return nil }
        return inflated.truncated ? text + "\n… (truncated; decompressed preview)" : text
    }

    /// Strip a gzip/zlib wrapper down to the raw DEFLATE stream that `COMPRESSION_ZLIB` expects
    /// (Apple's `COMPRESSION_ZLIB` is RFC 1951 raw DEFLATE, not the zlib/gzip wrapper).
    private static func rawDeflatePayload(of d: Data) -> Data? {
        let s = d.startIndex
        // gzip: 0x1f 0x8b, CM=0x08 (deflate). 10-byte fixed header + optional fields, 8-byte trailer.
        if d.count > 18, d[s] == 0x1f, d[s + 1] == 0x8b, d[s + 2] == 0x08 {
            let flg = d[s + 3]
            var i = s + 10
            if flg & 0x04 != 0 {                       // FEXTRA: 2-byte length then that many bytes
                guard i + 2 <= d.endIndex else { return nil }
                i += 2 + (Int(d[i]) | (Int(d[i + 1]) << 8))
            }
            if flg & 0x08 != 0 { i = skipZeroTerminated(d, from: i) }  // FNAME
            if flg & 0x10 != 0 { i = skipZeroTerminated(d, from: i) }  // FCOMMENT
            if flg & 0x02 != 0 { i += 2 }                              // FHCRC
            guard i < d.endIndex - 8 else { return nil }
            return Data(d[i..<(d.endIndex - 8)])
        }
        // zlib: CMF=0x78, FLG one of the standard checksummed bytes. 2-byte header + 4-byte Adler32.
        if d.count > 6, d[s] == 0x78, [0x01, 0x5e, 0x9c, 0xda].contains(d[s + 1]) {
            return Data(d[(s + 2)..<(d.endIndex - 4)])
        }
        return nil
    }

    private static func skipZeroTerminated(_ d: Data, from: Int) -> Int {
        var i = from
        while i < d.endIndex, d[i] != 0 { i += 1 }
        return min(i + 1, d.endIndex)   // step past the NUL
    }

    private static func inflate(_ deflate: Data) -> (data: Data, truncated: Bool)? {
        guard !deflate.isEmpty else { return nil }
        var out = Data(count: outputCap)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            deflate.withUnsafeBytes { src -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, outputCap, srcBase, deflate.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written..<out.count)
        return (out, written == outputCap)
    }
}
