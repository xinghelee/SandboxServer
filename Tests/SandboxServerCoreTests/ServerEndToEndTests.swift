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

    func testPluginsManifestListsAllThree() async throws {
        let (json, status) = try await getJSON("\(apiBase!)/plugins", token: token)
        XCTAssertEqual(status, 200)
        let items = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let ids = Set(items.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["net", "fs", "db"])
        // The network plugin must advertise its MCP tools so the bridge can register them.
        let net = items.first { $0["id"] as? String == "net" }
        let tools = (net?["mcpTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(tools.contains("net_list_requests"))
    }

    func testUnauthorizedWithoutToken() async throws {
        let (_, status) = try await getJSON("\(apiBase!)/plugins", token: nil)
        XCTAssertEqual(status, 401)
    }

    func testStubReturnsNotImplemented() async throws {
        let (json, status) = try await getJSON("\(apiBase!)/fs/list?path=/", token: token)
        XCTAssertEqual(status, 501)
        XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "not_implemented")
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

    private func getJSON(_ urlString: String, token: String?) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: urlString)))
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
