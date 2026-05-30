import XCTest
#if SandboxServerEnabled
@testable import SandboxServerCore

final class WebSocketCodecTests: XCTestCase {
    /// RFC 6455 §1.3 worked example.
    func testAcceptKeyMatchesRFCExample() {
        XCTAssertEqual(
            WebSocketCodec.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testEncodeProducesUnmaskedTextFrame() {
        let frame = WebSocketCodec.encodeText("hi")
        XCTAssertEqual(frame[0], 0x81)        // FIN + text opcode
        XCTAssertEqual(frame[1], 2)           // length 2, mask bit clear
        XCTAssertEqual(Array(frame[2...]), Array("hi".utf8))
    }

    func testDecodeMaskedClientFrame() {
        let payload = Array("subscribe".utf8)
        let mask: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        var bytes: [UInt8] = [0x81, UInt8(0x80 | payload.count)] + mask
        bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }

        var buffer = bytes
        let frames = WebSocketCodec.decode(&buffer)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.opcode, .text)
        XCTAssertEqual(frames.first.map { String(decoding: $0.payload, as: UTF8.self) }, "subscribe")
        XCTAssertTrue(buffer.isEmpty, "a complete frame should be fully consumed")
    }

    func testDecodeLeavesPartialFrameBuffered() {
        var buffer: [UInt8] = [0x81] // header only; incomplete
        let frames = WebSocketCodec.decode(&buffer)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(buffer, [0x81], "incomplete bytes must remain for the next read")
    }

    func testExtendedLength16RoundTrips() {
        let big = [UInt8](repeating: 0x41, count: 300)
        let frame = WebSocketCodec.encode(.binary, big)
        XCTAssertEqual(frame[1], 126)         // 16-bit length marker
        XCTAssertEqual(Int(frame[2]) << 8 | Int(frame[3]), 300)
    }

    func testDecodeRefusesOversizeFrameWithClose1009() {
        // A masked binary frame claiming a 16-bit length of 65535, but no payload bytes sent — the
        // cap must reject it (so we never buffer up to 64 KiB of attacker-controlled bytes) and
        // signal Close 1009, dropping the buffer rather than waiting for the rest.
        var buffer: [UInt8] = [0x82, UInt8(0x80 | 126), 0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04]
        let frames = WebSocketCodec.decode(&buffer, maxPayload: 1024)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.opcode, .close)
        XCTAssertEqual(frames.first?.payload, WebSocketCodec.closeMessageTooBig) // 1009
        XCTAssertTrue(buffer.isEmpty, "the oversized frame's bytes are dropped, not retained")
    }

    func testDecodeRefusesMalformedNegativeLength() {
        // A 64-bit (127) length with the high bit set parses to a negative Int — previously an
        // invalid slice (crash); now refused with Close 1009.
        var buffer: [UInt8] = [0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0] // len high bit set
        let frames = WebSocketCodec.decode(&buffer, maxPayload: WebSocketCodec.maxFramePayloadBytes)
        XCTAssertEqual(frames.first?.opcode, .close)
    }

    func testDecodeAllowsFrameAtTheCap() {
        // A normal (unmasked, server-style) frame under the cap still decodes.
        let body = [UInt8](repeating: 0x41, count: 300)
        var buffer = WebSocketCodec.encode(.binary, body)
        let frames = WebSocketCodec.decode(&buffer, maxPayload: 1024)
        XCTAssertEqual(frames.first?.opcode, .binary)
        XCTAssertEqual(frames.first?.payload.count, 300)
    }
}
#endif
