import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// The optional, display-only `networkBodyDecoder` hook: it renders an encrypted/encoded body as
/// readable text for the console/MCP, falls back to the built-in preview when it declines, and —
/// crucially — never touches the raw bytes kept for replay (i.e. it can't alter host-app logic).
final class NetworkBodyDecoderTests: XCTestCase {

    private func store(decoder: NetworkBodyDecoder?) async -> TransactionStore {
        let s = TransactionStore()
        await s.attach(context: StubCtx(decoder: decoder))
        return s
    }

    /// A body that is gibberish as UTF-8 and not "text" by content-type — the built-in preview would
    /// render it as `<binary N bytes>`, so a non-nil result proves the decoder ran.
    private let cipher = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x80, 0x81])

    func testDecoderRendersRequestAndResponseBodies() async throws {
        let s = await store(decoder: { body in
            // Stand-in for a host decrypting its own envelope; branch on direction to prove wiring.
            let tag = body.direction == .request ? "REQ" : "RESP"
            return "\(tag)::decoded \(body.body.count)B"
        })

        await s.begin(id: "t1", method: "POST", url: URL(string: "https://api.example.com/v1/secure"),
                      headers: ["content-type": "application/octet-stream"], reqBody: cipher)
        await s.complete(id: "t1", status: 200, headers: [:], body: cipher,
                         contentType: "application/octet-stream")

        let result = await s.detail(id: "t1", include: ["reqBody", "respBody"])
        let detail = try XCTUnwrap(result)
        XCTAssertEqual(detail.reqBody, "REQ::decoded 7B")
        XCTAssertEqual(detail.respBody, "RESP::decoded 7B")
    }

    func testNilFromDecoderFallsBackToBuiltInPreview() async throws {
        // Decoder declines (returns nil) → the built-in binary fallback must still apply.
        let s = await store(decoder: { _ in nil })
        await s.begin(id: "t2", method: "POST", url: URL(string: "https://api.example.com/x"),
                      headers: ["content-type": "application/octet-stream"], reqBody: cipher)
        let result = await s.detail(id: "t2", include: ["reqBody"])
        let detail = try XCTUnwrap(result)
        XCTAssertEqual(detail.reqBody, "<binary 7 bytes>")
    }

    func testDecoderIsDisplayOnly_replayKeepsRawBytes() async throws {
        // Even with a decoder active, replay must re-issue the ORIGINAL raw bytes, never the
        // decoded text — this is the guarantee that the hook can't alter the integrating app.
        let s = await store(decoder: { _ in "DECODED — must never reach replay" })
        await s.begin(id: "t3", method: "POST", url: URL(string: "https://api.example.com/secure"),
                      headers: ["content-type": "application/octet-stream"], reqBody: cipher)

        let raw = await s.replayPayload(id: "t3")
        let payload = try XCTUnwrap(raw)
        XCTAssertEqual(payload.body, cipher, "replay must use the captured raw bytes, not the decoded preview")
    }

    // MARK: - Built-in key-free decoders (gzip / zlib), no host hook needed

    /// Real `gzip` + `zlib` byte vectors of the same UTF-8 string (generated with Python's gzip/zlib).
    private let plaintext = "hello sandbox — decode hook 中文 🎉"
    private let gzipped = Data([31,139,8,0,79,77,28,106,2,255,203,72,205,201,201,87,40,78,204,75,73,202,175,80,120,212,48,69,33,37,53,57,63,37,85,33,35,63,63,91,225,201,142,181,207,166,181,43,124,152,223,215,9,0,40,94,164,77,41,0,0,0])
    private let zlibbed = Data([120,218,203,72,205,201,201,87,40,78,204,75,73,202,175,80,120,212,48,69,33,37,53,57,63,37,85,33,35,63,63,91,225,201,142,181,207,166,181,43,124,152,223,215,9,0,103,190,18,193])

    func testBuiltInGzipAndZlibDecodeWithNoHostHook() async throws {
        let s = await store(decoder: nil)
        await s.begin(id: "g", method: "POST", url: URL(string: "https://api.example.com/gz"),
                      headers: ["content-type": "application/octet-stream"], reqBody: gzipped)
        await s.complete(id: "g", status: 200, headers: [:], body: zlibbed,
                         contentType: "application/octet-stream")
        let result = await s.detail(id: "g", include: ["reqBody", "respBody"])
        let detail = try XCTUnwrap(result)
        XCTAssertEqual(detail.reqBody, plaintext, "gzip body should auto-inflate")
        XCTAssertEqual(detail.respBody, plaintext, "zlib body should auto-inflate")
    }

    func testHostDecoderTakesPrecedenceOverBuiltIn() async throws {
        // A host hook wins even for a gzip body — it sees the raw bytes and decides.
        let s = await store(decoder: { _ in "HOST WON" })
        await s.begin(id: "p", method: "POST", url: URL(string: "https://api.example.com/gz"),
                      headers: ["content-type": "application/octet-stream"], reqBody: gzipped)
        let result = await s.detail(id: "p", include: ["reqBody"])
        let detail = try XCTUnwrap(result)
        XCTAssertEqual(detail.reqBody, "HOST WON")
    }

    private final class StubCtx: PluginContext, @unchecked Sendable {
        private let cfg: SandboxConfig
        init(decoder: NetworkBodyDecoder?) { cfg = SandboxConfig(networkBodyDecoder: decoder) }
        func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {}
        func extraRoots() -> [URL] { [] }
        func hostValue<Value>(_ key: HostValueKey<Value>) -> Value? { nil }
        var config: SandboxConfig { cfg }
        func log(_ message: @autoclosure () -> String) {}
    }
}
#endif
