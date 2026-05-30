import Foundation
import CryptoKit

enum WSOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WSFrame: Sendable {
    let fin: Bool
    let opcode: WSOpcode
    let payload: [UInt8]
}

/// Minimal RFC 6455 codec: server-side handshake plus frame encode/decode.
///
/// Server→client frames are never masked; client→server frames must be (and are unmasked
/// here). The control protocol uses small single-frame text messages, so application-level
/// fragmentation reassembly is intentionally not implemented; ping/pong/close are handled.
enum WebSocketCodec {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Upper bound on a single inbound frame's declared payload length, mirroring the HTTP body
    /// cap. A frame claiming more (or a malformed negative length) is refused with Close 1009
    /// instead of buffering attacker-controlled bytes up to that length.
    static let maxFramePayloadBytes = 1 << 20 // 1 MiB
    /// Close status 1009 "message too big", big-endian, as a close-frame payload.
    static let closeMessageTooBig: [UInt8] = [0x03, 0xF1]

    /// `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`.
    static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Builds the `101 Switching Protocols` response bytes.
    static func handshakeResponse(acceptKey: String) -> [UInt8] {
        let lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)",
        ]
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func encode(_ opcode: WSOpcode, _ payload: [UInt8], fin: Bool = true) -> [UInt8] {
        var frame: [UInt8] = [(fin ? 0x80 : 0x00) | opcode.rawValue]
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((len >> shift) & 0xFF)) }
        }
        frame.append(contentsOf: payload) // unmasked (server → client)
        return frame
    }

    static func encodeText(_ string: String) -> [UInt8] { encode(.text, Array(string.utf8)) }

    /// Extracts every complete frame from `buffer`, consuming their bytes; incomplete
    /// trailing data is left for the next read.
    static func decode(_ buffer: inout [UInt8], maxPayload: Int = .max) -> [WSFrame] {
        var frames: [WSFrame] = []
        while true {
            guard buffer.count >= 2 else { break }
            let b0 = buffer[0], b1 = buffer[1]
            let fin = (b0 & 0x80) != 0
            guard let opcode = WSOpcode(rawValue: b0 & 0x0F) else { buffer.removeFirst(); continue }
            let masked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var offset = 2
            if payloadLen == 126 {
                guard buffer.count >= offset + 2 else { break }
                payloadLen = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
                offset += 2
            } else if payloadLen == 127 {
                guard buffer.count >= offset + 8 else { break }
                var value = 0
                for i in 0..<8 { value = (value << 8) | Int(buffer[offset + i]) }
                payloadLen = value
                offset += 8
            }
            // Refuse an oversized (or a malformed negative, from a 127-frame with bit 63 set) length
            // before waiting for / allocating that many bytes: drop the buffer and signal Close 1009.
            if payloadLen < 0 || payloadLen > maxPayload {
                buffer.removeAll(keepingCapacity: false)
                frames.append(WSFrame(fin: true, opcode: .close, payload: closeMessageTooBig))
                break
            }
            var maskKey: [UInt8] = []
            if masked {
                guard buffer.count >= offset + 4 else { break }
                maskKey = Array(buffer[offset..<offset + 4])
                offset += 4
            }
            guard buffer.count >= offset + payloadLen else { break }
            var payload = Array(buffer[offset..<offset + payloadLen])
            if masked { for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] } }
            buffer.removeFirst(offset + payloadLen)
            frames.append(WSFrame(fin: fin, opcode: opcode, payload: payload))
        }
        return frames
    }
}
