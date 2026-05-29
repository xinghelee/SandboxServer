import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

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
        XCTAssertEqual(ids, ["net", "fs", "db", "logs", "screen"])
        // The network plugin must advertise its MCP tools so the bridge can register them.
        let net = items.first { $0["id"] as? String == "net" }
        let netTools = (net?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(netTools.contains("net_list_requests"))
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

    // MARK: helpers

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
