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
        XCTAssertEqual(ids, ["net", "fs", "db", "logs", "screen", "hierarchy", "ws", "bundle", "perf", "defaults", "device", "deeplink"])
        // The bundle plugin advertises its inspector tools.
        let bundle = items.first { $0["id"] as? String == "bundle" }
        let bundleTools = (bundle?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(bundleTools.contains("bundle_macho"))
        XCTAssertTrue(bundleTools.contains("bundle_security"))
        XCTAssertTrue(bundleTools.contains("bundle_decode_plist"))
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
        // The websocket plugin advertises its capture tools + channel.
        let ws = items.first { $0["id"] as? String == "ws" }
        XCTAssertEqual(ws?["channels"] as? [String], ["ws"])
        let wsTools = (ws?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(wsTools.contains("ws_list_connections"))
        XCTAssertTrue(wsTools.contains("ws_list_messages"))
    }

    func testWebSocketConnectionsEndpointIsLive() async throws {
        // No traffic captured on the test host, but the route is mounted and returns an empty list.
        let (json, status) = try await getJSON("\(apiBase!)/ws/connections", token: token)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil((json["data"] as? [String: Any])?["items"] as? [Any], "ws/connections should return an items array")
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

    func testDefaultAuthIsOpenIncludingLocalNetwork() async throws {
        let openServer = SandboxServerCore()
        let result = await openServer.start(SandboxConfig(
            bindingPolicy: .localNetwork, auth: .none, builtInPlugins: .none, preferredPort: 0
        ))
        guard case .started(let info) = result else {
            return XCTFail("open localNetwork server failed to start: \(result)")
        }
        XCTAssertNil(info.token)
        XCTAssertEqual(info.bindingPolicy, .localNetwork)

        let json: [String: Any]
        let status: Int
        do {
            let response = try await getJSON("http://127.0.0.1:\(info.port)/__sandbox/api/v1/healthz", token: nil)
            json = response.0
            status = response.1
            await openServer.stop()
        } catch {
            await openServer.stop()
            throw error
        }

        XCTAssertEqual(status, 200)
        let data = json["data"] as? [String: Any]
        XCTAssertEqual(data?["bindingPolicy"] as? String, "localNetwork")
        XCTAssertEqual(data?["requiresAuth"] as? Bool, false)
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

        // Replay can also edit the request line: method and URL are first-class overrides.
        let (lineJSON, lineStatus) = try await getJSON(
            "\(apiBase!)/net/requests/\(id)/replay", token: token, method: "POST",
            jsonBody: ["method": "POST", "url": "\(apiBase!)/plugins"]
        )
        XCTAssertEqual(lineStatus, 200)
        let line = lineJSON["data"] as? [String: Any]
        XCTAssertEqual(line?["method"] as? String, "POST")
        XCTAssertTrue((line?["url"] as? String)?.contains("/plugins") ?? false)
        XCTAssertEqual(line?["status"] as? Int, 200)

        // Replay WITH a header override: it MERGES onto the captured (unredacted) headers. Because it
        // merges (not replaces), the original auth survives without being re-sent — so the replay is
        // still authorized (status 200) and the override header shows up on the new transaction.
        let (ovJSON, ovStatus) = try await getJSON(
            "\(apiBase!)/net/requests/\(id)/replay", token: token, method: "POST",
            jsonBody: ["headers": ["X-Replay-Tag": "1"]]
        )
        XCTAssertEqual(ovStatus, 200)
        let ov = ovJSON["data"] as? [String: Any]
        XCTAssertEqual(ov?["status"] as? Int, 200, "merge preserves the original auth, so the replay stays authorized")
        XCTAssertEqual((ov?["reqHeaders"] as? [String: String])?["X-Replay-Tag"], "1",
                       "the override header should be merged into the replayed request")

        // Case-insensitive override: the captured probe sent "Authorization"; a lowercase
        // "authorization" override must WIN (not coexist as a duplicate key), so a bad token is
        // deterministically rejected — proving the merge canonicalises header names by case.
        let (ciJSON, ciStatus) = try await getJSON(
            "\(apiBase!)/net/requests/\(id)/replay", token: token, method: "POST",
            jsonBody: ["headers": ["authorization": "Bearer not-the-real-token"]]
        )
        XCTAssertEqual(ciStatus, 200, "the replay route succeeds; the replayed call's own status is reported in data")
        XCTAssertEqual((ciJSON["data"] as? [String: Any])?["status"] as? Int, 401,
                       "a lowercase 'authorization' override must replace the captured 'Authorization', so the bad token is rejected")

        // An unknown id is a clean 404, not a 501/500.
        let (errJSON, errStatus) = try await getJSON("\(apiBase!)/net/requests/does-not-exist/replay",
                                                     token: token, method: "POST")
        XCTAssertEqual(errStatus, 404)
        XCTAssertEqual((errJSON["error"] as? [String: Any])?["code"] as? String, "not_found")
    }

    func testNetReplayBodyOverride() async throws {
        // Capture a POST, then replay it with a body override; the new transaction must record the
        // overridden body (its byte count), proving the base64 body-replacement path end-to-end.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SandboxURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)

        var probe = URLRequest(url: try XCTUnwrap(URL(string: "\(apiBase!)/db/x/query")))
        probe.httpMethod = "POST"
        probe.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.httpBody = Data(#"{"sql":"SELECT 1"}"#.utf8)
        _ = try await session.data(for: probe)

        var capturedID: String?
        for _ in 0..<20 {
            let (json, _) = try await getJSON("\(apiBase!)/net/requests?method=POST", token: token)
            let items = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            if let hit = items.first(where: { ($0["url"] as? String)?.contains("/db/x/query") ?? false }) {
                capturedID = hit["id"] as? String
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let id = try XCTUnwrap(capturedID, "the POST probe was not captured")

        let overrideBody = "hello-body"
        let (ovJSON, ovStatus) = try await getJSON(
            "\(apiBase!)/net/requests/\(id)/replay", token: token, method: "POST",
            jsonBody: ["body": Data(overrideBody.utf8).base64EncodedString()]
        )
        XCTAssertEqual(ovStatus, 200, "the replay route itself succeeds even if the replayed call returns non-2xx")
        let ov = ovJSON["data"] as? [String: Any]
        XCTAssertEqual(ov?["reqBytes"] as? Int, overrideBody.utf8.count,
                       "the overridden body's byte count should be recorded on the new transaction")
        XCTAssertNotEqual(ov?["id"] as? String, id, "replay must create a NEW transaction")
    }

    func testBundleEndpoints() async throws {
        // Summary + Mach-O + provisioning + privacy all answer with well-formed envelopes on the
        // macOS test host (graceful degradation), and the Mach-O parser works against the real
        // test-runner binary.
        let (summary, s1) = try await getJSON("\(apiBase!)/bundle", token: token)
        XCTAssertEqual(s1, 200)
        let sdata = summary["data"] as? [String: Any]
        XCTAssertNotNil(sdata?["bundlePath"], "summary should report the bundle path")

        let (macho, s2) = try await getJSON("\(apiBase!)/bundle/macho", token: token)
        XCTAssertEqual(s2, 200)
        let mdata = macho["data"] as? [String: Any]
        XCTAssertEqual(mdata?["supported"] as? Bool, true, "the test runner is itself a real Mach-O")
        XCTAssertGreaterThanOrEqual((mdata?["slices"] as? [[String: Any]])?.count ?? 0, 1)

        let (prov, s3) = try await getJSON("\(apiBase!)/bundle/provisioning", token: token)
        XCTAssertEqual(s3, 200)
        XCTAssertEqual((prov["data"] as? [String: Any])?["present"] as? Bool, false,
                       "the macOS test runner has no embedded.mobileprovision")

        let (_, s4) = try await getJSON("\(apiBase!)/bundle/privacy", token: token)
        XCTAssertEqual(s4, 200)

        // The app bundle is auto-registered as a READ-ONLY root: a write into it is a clean 403,
        // not an opaque OS io_error.
        if let bundlePath = sdata?["bundlePath"] as? String {
            let target = "\(bundlePath)/sbx-readonly-probe.txt"
            let enc = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target
            let (err, s5) = try await getJSON("\(apiBase!)/fs/file?path=\(enc)", token: token,
                                              method: "PUT", jsonBody: ["content": "x"])
            XCTAssertEqual(s5, 403, "writing into the read-only app-bundle root must be refused")
            XCTAssertEqual((err["error"] as? [String: Any])?["code"] as? String, "forbidden")
        }
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

    func testWebSocketUpgradeRejectsUnsupportedVersion() throws {
        let comps = try XCTUnwrap(URLComponents(string: apiBase))
        let port = UInt16(try XCTUnwrap(comps.port))
        func upgrade(version: String) -> String {
            "GET /__sandbox/ws HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(port)\r\n"
                + "Authorization: Bearer \(token!)\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                + "Sec-WebSocket-Version: \(version)\r\n\r\n"
        }
        // Unsupported version → 426 advertising the version we speak.
        let bad = try XCTUnwrap(rawHTTP(upgrade(version: "8"), host: "127.0.0.1", port: port))
        XCTAssertTrue(bad.hasPrefix("HTTP/1.1 426"), "expected 426, got: \(bad.prefix(40))")
        XCTAssertTrue(bad.contains("Sec-WebSocket-Version: 13"), "426 must advertise the supported version")
        // Version 13 → the handshake completes (101).
        let ok = try XCTUnwrap(rawHTTP(upgrade(version: "13"), host: "127.0.0.1", port: port))
        XCTAssertTrue(ok.contains("101 Switching Protocols"), "v13 upgrade should succeed, got: \(ok.prefix(40))")
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

    private func getJSON(_ urlString: String, token: String?, method: String = "GET",
                         jsonBody: [String: Any]? = nil) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: urlString)))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, status)
    }
}
#endif
