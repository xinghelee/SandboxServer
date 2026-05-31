import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// NotifyPlugin: the JSON→Foundation payload conversion, plus the non-UIKit degradation path
/// (these tests run on the macOS host, where UIKit/UserNotifications work is gated off and the
/// notification center is never touched).
final class NotifyPluginTests: XCTestCase {

    // MARK: - Payload conversion

    func testAnyValueBuildsAFoundationGraph() {
        let json: JSONValue = .object([
            "aps": .object(["alert": .string("hi"), "badge": .int(3)]),
            "flag": .bool(true),
            "items": .array([.int(1), .double(2.5), .string("x")]),
            "nothing": .null,
        ])
        let any = NotifyPlugin.anyValue(from: json)
        let dict = try? XCTUnwrap(any as? [String: Any])
        XCTAssertEqual((dict?["flag"] as? Bool), true)
        let aps = dict?["aps"] as? [String: Any]
        XCTAssertEqual(aps?["alert"] as? String, "hi")
        XCTAssertEqual(aps?["badge"] as? Int, 3)
        XCTAssertEqual((dict?["items"] as? [Any])?.count, 3)
        XCTAssertTrue(dict?["nothing"] is NSNull)
    }

    // MARK: - Degradation off-iOS

    func testSettingsReportsUnsupportedWithoutUIKit() async throws {
        let resp = try await runRoute("GET", "")
        XCTAssertEqual(resp.status, 200)
        guard case .json(let data) = resp.body else { return XCTFail("expected json body") }
        struct Env: Decodable { let data: Settings }
        struct Settings: Decodable { let supported: Bool; let authorizationStatus: String }
        let s = try JSONDecoder().decode(Env.self, from: data).data
        #if !canImport(UIKit)
        XCTAssertFalse(s.supported)
        XCTAssertEqual(s.authorizationStatus, "unsupported")
        #endif
    }

    #if !canImport(UIKit)
    func testActionRoutesAre503WithoutUIKit() async throws {
        let local = try await runRoute("POST", "local", json: #"{"title":"hi"}"#)
        XCTAssertEqual(local.status, 503)
        let clear = try await runRoute("DELETE", "")
        XCTAssertEqual(clear.status, 503)
        let remote = try await runRoute("POST", "remote", json: #"{"payload":{"aps":{}}}"#)
        XCTAssertEqual(remote.status, 503)
    }
    #endif

    func testCapabilitiesAdvertiseTheToolSet() {
        let tools = NotifyPlugin().capabilities.mcpTools.map(\.name)
        XCTAssertEqual(
            Set(tools),
            ["notify_settings", "notify_request_auth", "notify_send_local", "notify_list_pending",
             "notify_list_delivered", "notify_simulate_remote", "notify_clear"]
        )
        // The clear tool must be flagged destructive.
        let clear = NotifyPlugin().capabilities.mcpTools.first { $0.name == "notify_clear" }
        XCTAssertEqual(clear?.destructiveHint, true)
    }

    // MARK: - Harness

    private func runRoute(_ method: String, _ suffix: String, json: String? = nil) async throws -> SBResponse {
        let plugin = NotifyPlugin()
        let r = try XCTUnwrap(plugin.routes().first { $0.method == method && $0.pathSuffix == suffix })
        let body = json.map { Data($0.utf8) }
        let req = SBRequest(method: method, path: suffix, body: {
            AsyncThrowingStream { cont in
                if let body { cont.yield(ArraySlice(body)) }
                cont.finish()
            }
        })
        return try await r.handler(req, StubCtx())
    }

    private final class StubCtx: PluginContext, @unchecked Sendable {
        func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {}
        func extraRoots() -> [URL] { [] }
        func hostValue<Value>(_ key: HostValueKey<Value>) -> Value? { nil }
        var config: SandboxConfig { SandboxConfig() }
        func log(_ message: @autoclosure () -> String) {}
    }
}
#endif
