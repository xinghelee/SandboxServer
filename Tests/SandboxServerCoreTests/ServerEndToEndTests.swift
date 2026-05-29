import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore
#if canImport(Darwin)
import Darwin
#endif

/// Boots a real `SandboxServerCore` on loopback and exercises the full stack over HTTP:
/// transport → middleware/auth → router → plugins, plus live network capture.
final class ServerEndToEndTests: XCTestCase {
    private var server: SandboxServerCore!
    private var token: String!
    private var apiBase: String!

    override func setUp() async throws {
        server = SandboxServerCore()
        let result = await server.start(SandboxConfig(
            bindingPolicy: .loopback, auth: .token, builtInPlugins: .all, preferredPort: 0
        ))
        guard case .started(let info) = result else {
            return XCTFail("server failed to start: \(result)")
        }
        token = try XCTUnwrap(info.token)
        apiBase = info.apiBaseURL.absoluteString
    }

    override func tearDown() async throws {
        await server?.stop()
        server = nil
    }

    func testHealthz() async throws {
        let (json, status) = try await getJSON("\(apiBase!)/healthz", token: token)
        XCTAssertEqual(status, 200)
        let data = json["data"] as? [String: Any]
        XCTAssertEqual(data?["apiVersion"] as? String, "1")
        XCTAssertEqual(data?["bindingPolicy"] as? String, "loopback")
        XCTAssertEqual(data?["requiresAuth"] as? Bool, true)
    }

    func testPluginsManifestListsAllBuiltins() async throws {
        let (json, status) = try await getJSON("\(apiBase!)/plugins", token: token)
        XCTAssertEqual(status, 200)
        let items = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let ids = Set(items.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["net", "fs", "db", "logs", "screen", "hierarchy"])
        // The network plugin must advertise its MCP tools so the bridge can register them.
        let net = items.first { $0["id"] as? String == "net" }
        let netTools = (net?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(netTools.contains("net_list_requests"))
        // It also documents its capture blind spots so the console/MCP can surface them (B1).
        let netLimits = (net?["limitations"] as? [String]) ?? []
        XCTAssertFalse(netLimits.isEmpty, "net plugin should advertise capture limitations")
        XCTAssertTrue(netLimits.contains { $0.contains("WKWebView") },
                      "limitations should name the known blind spots")
        // Plugins without caveats omit the field entirely (additive/optional manifest contract).
        let fs = items.first { $0["id"] as? String == "fs" }
        XCTAssertNil(fs?["limitations"], "limitations is omitted when nil, not serialized as null")
        // The logs plugin advertises the logs channel + its tail/search/clear tools.
        let logs = items.first { $0["id"] as? String == "logs" }
        XCTAssertEqual(logs?["channels"] as? [String], ["logs"])
        let logTools = (logs?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(logTools.contains("logs_tail"))
        // The screen plugin advertises its UI-control tools so AI/the console can drive the app.
        let screen = items.first { $0["id"] as? String == "screen" }
        let uiTools = (screen?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(uiTools.contains("ui_tap"))
        XCTAssertTrue(uiTools.contains("ui_screenshot"))
        XCTAssertTrue(uiTools.contains("ui_swipe"))
        // The hierarchy plugin advertises the view-tree tool.
        let hierarchy = items.first { $0["id"] as? String == "hierarchy" }
        let hTools = (hierarchy?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(hTools.contains("ui_hierarchy"))
    }

    func testHierarchyUnsupportedOnHost() async throws {
        // No UIKit on the macOS test host → the tree reports unsupported (still HTTP 200).
        let (json, status) = try await getJSON("\(apiBase!)/hierarchy", token: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((json["data"] as? [String: Any])?["supported"] as? Bool, false)
    }

    func testScreenControlUnsupportedOnHost() async throws {
        // The macOS test host has no UIKit, so the screen plugin reports unsupported and 503s capture.
        let (info, infoStatus) = try await getJSON("\(apiBase!)/screen", token: token)
        XCTAssertEqual(infoStatus, 200)
        XCTAssertEqual((info["data"] as? [String: Any])?["supported"] as? Bool, false)

        let (frame, frameStatus) = try await getJSON("\(apiBase!)/screen/frame", token: token)
        XCTAssertEqual(frameStatus, 503)
        XCTAssertEqual((frame["error"] as? [String: Any])?["code"] as? String, "screen_unavailable")
    }

    func testUnauthorizedWithoutToken() async throws {
        let (_, status) = try await getJSON("\(apiBase!)/plugins", token: nil)
        XCTAssertEqual(status, 401)
    }

    func testFilesListingIsLive() async throws {
        let (json, status) = try await getJSON("\(apiBase!)/fs/list", token: token)
        XCTAssertEqual(status, 200)
        let data = json["data"] as? [String: Any]
        XCTAssertNotNil(data?["items"] as? [Any], "fs/list should return an items array")
        XCTAssertNotNil(data?["path"] as? String, "fs/list should report the resolved path")
    }

    func testDbExecIsReadOnly() async throws {
        let (json, status) = try await getJSON("\(apiBase!)/db/x/exec", token: token, method: "POST")
        XCTAssertEqual(status, 403)
        XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "db_readonly")
    }

    func testLogsCaptureIsLive() async throws {
        // A host log emitted through the SDK must surface on the logs plugin's REST endpoint.
        let marker = "E2E-LOG-\(UUID().uuidString)"
        server.log(marker, level: "warn", category: "test")

        let (json, status) = try await getJSON("\(apiBase!)/logs?q=\(marker)", token: token)
        XCTAssertEqual(status, 200)
        let items = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let hit = items.first { ($0["message"] as? String) == marker }
        XCTAssertNotNil(hit, "the emitted log line should be captured and listable")
        XCTAssertEqual(hit?["level"] as? String, "warn")
        XCTAssertEqual(hit?["source"] as? String, "app")
    }

    func testLiveNetworkCapture() async throws {
        // A session that explicitly routes through our protocol — deterministic capture.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SandboxURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)

        var probe = URLRequest(url: try XCTUnwrap(URL(string: "\(apiBase!)/healthz")))
        probe.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: probe)

        // Poll the capture store (the protocol records asynchronously).
        var captured: [[String: Any]] = []
        for _ in 0..<20 {
            let (json, _) = try await getJSON("\(apiBase!)/net/requests", token: token)
            captured = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            if !captured.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(captured.isEmpty, "the probe request should have been captured")
        XCTAssertTrue(captured.contains { ($0["url"] as? String)?.contains("/healthz") ?? false })
    }

    func testCapturesRequestBody() async throws {
        // URLSession turns httpBody into an httpBodyStream before the protocol sees it; drainBody
        // must recover it so the captured transaction has a non-empty request body (#4).
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SandboxURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)

        let marker = "BODY-\(UUID().uuidString)"
        var req = URLRequest(url: try XCTUnwrap(URL(string: "\(apiBase!)/healthz")))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"probe\":\"\(marker)\"}".utf8)
        _ = try await session.data(for: req)

        var body: String?
        for _ in 0..<20 {
            let (list, _) = try await getJSON("\(apiBase!)/net/requests", token: token)
            let items = ((list["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            if let hit = items.first(where: { ($0["method"] as? String) == "POST" }) {
                let id = hit["id"] as? String ?? ""
                let (d, _) = try await getJSON("\(apiBase!)/net/requests/\(id)?include=reqBody", token: token)
                body = (d["data"] as? [String: Any])?["reqBody"] as? String
                if body?.contains(marker) == true { break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(body, "request body should be captured (drained from the body stream)")
        XCTAssertTrue(body?.contains(marker) ?? false, "captured body should contain the sent payload")
    }

    func testNetReplayRequest() async throws {
        // Capture a probe through our protocol, then replay it (C1).
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SandboxURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)

        var probe = URLRequest(url: try XCTUnwrap(URL(string: "\(apiBase!)/healthz")))
        probe.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: probe)

        var capturedID: String?
        for _ in 0..<20 {
            let (json, _) = try await getJSON("\(apiBase!)/net/requests", token: token)
            let items = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            if let hit = items.first(where: { ($0["url"] as? String)?.contains("/healthz") ?? false }) {
                capturedID = hit["id"] as? String
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let id = try XCTUnwrap(capturedID, "the probe was not captured")

        // Replay with no overrides: it re-issues GET /healthz with the original (unredacted) auth.
        let (replayJSON, replayStatus) = try await getJSON("\(apiBase!)/net/requests/\(id)/replay",
                                                           token: token, method: "POST")
        XCTAssertEqual(replayStatus, 200)
        let detail = replayJSON["data"] as? [String: Any]
        XCTAssertEqual(detail?["method"] as? String, "GET")
        XCTAssertTrue((detail?["url"] as? String)?.contains("/healthz") ?? false)
        XCTAssertEqual(detail?["status"] as? Int, 200, "replay should re-hit /healthz with the original auth")
        let newID = try XCTUnwrap(detail?["id"] as? String)
        XCTAssertNotEqual(newID, id, "replay must create a NEW transaction, not mutate the original")

        // An unknown id is a clean 404, not a 501/500.
        let (errJSON, errStatus) = try await getJSON("\(apiBase!)/net/requests/does-not-exist/replay",
                                                     token: token, method: "POST")
        XCTAssertEqual(errStatus, 404)
        XCTAssertEqual((errJSON["error"] as? [String: Any])?["code"] as? String, "not_found")
    }

    func testOversizeRequestBodyReturns413() throws {
        // A hostile/buggy Content-Length must be rejected up front (no multi-MiB read) with a 413
        // carrying the correct RFC reason phrase. A raw socket lets us lie about Content-Length
        // without ever sending the body — proving the cap fires on the declared length alone.
        let comps = try XCTUnwrap(URLComponents(string: apiBase))
        let port = UInt16(try XCTUnwrap(comps.port))
        let oversized = HTTPConnectionReader.maxBodyBytes + 1
        let raw = "POST /__sandbox/api/v1/db/x/query HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Authorization: Bearer \(token!)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(oversized)\r\n"
            + "\r\n" // headers only — we never send the body we claimed
        let response = try XCTUnwrap(rawHTTP(raw, host: "127.0.0.1", port: port), "no response from server")
        let statusLine = response.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertTrue(statusLine.contains("413"), "expected 413, got status line: \(statusLine)")
        XCTAssertTrue(statusLine.contains("Payload Too Large"), "expected RFC reason phrase, got: \(statusLine)")
    }

    // MARK: helpers

    /// Sends a raw HTTP request over a fresh loopback TCP socket and returns the response text
    /// (read until the header terminator or the peer closes). macOS test host only.
    private func rawHTTP(_ request: String, host: String, port: UInt16) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var out = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<8 {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: chunk[0..<n])
            if let s = String(bytes: out, encoding: .utf8), s.contains("\r\n\r\n") { break }
        }
        return String(bytes: out, encoding: .utf8)
    }

    private func getJSON(_ urlString: String, token: String?, method: String = "GET") async throws -> ([String: Any], Int) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: urlString)))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, status)
    }
}
#endif
