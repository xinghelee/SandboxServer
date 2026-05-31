import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// DevicePlugin + DeepLinkPlugin: snapshot invariants and the non-UIKit degradation paths
/// (these tests run on the macOS host, where UIKit is absent).
final class DeviceAndDeepLinkPluginTests: XCTestCase {

    // MARK: - DevicePlugin

    func testDeviceSnapshotHasSaneBaseFields() async throws {
        let info = await DeviceInfo.capture()
        XCTAssertGreaterThan(info.memory.physicalMB, 0)
        XCTAssertGreaterThan(info.process.processorCount, 0)
        XCTAssertGreaterThanOrEqual(info.process.activeProcessorCount, 1)
        XCTAssertFalse(info.locale.identifier.isEmpty)
        XCTAssertFalse(info.hardware.machine.isEmpty)
        XCTAssertFalse(info.os.platform.isEmpty)
        XCTAssertFalse(info.locale.timeZone.isEmpty)
    }

    func testDeviceSnapshotEncodesAndOmitsUIKitFieldsOffDevice() async throws {
        let resp = try await runRoute(DevicePlugin(), "GET", "")
        XCTAssertEqual(resp.status, 200)
        guard case .json(let data) = resp.body else { return XCTFail("expected json body") }
        struct Env: Decodable { let data: Snapshot }
        struct Snapshot: Decodable {
            struct Mem: Decodable { let physicalMB: Double }
            let memory: Mem
            let screen: JSONValue?
            let battery: JSONValue?
        }
        let snap = try JSONDecoder().decode(Env.self, from: data).data
        XCTAssertGreaterThan(snap.memory.physicalMB, 0)
        #if !canImport(UIKit)
        XCTAssertNil(snap.screen, "screen geometry must be null on a non-UIKit host")
        XCTAssertNil(snap.battery)
        #endif
    }

    // MARK: - DeepLinkPlugin

    func testDeepLinkListSchemesNeverThrows() async throws {
        // The test bundle declares no URL types — the call must still return cleanly.
        XCTAssertNoThrow(DeepLinkPlugin.declaredURLTypes())
        let schemes = DeepLinkPlugin.declaredSchemes()
        XCTAssertEqual(schemes.count, Set(schemes).count, "schemes must be de-duplicated")
    }

    func testDeepLinkInfoRoute() async throws {
        let resp = try await runRoute(DeepLinkPlugin(), "GET", "")
        XCTAssertEqual(resp.status, 200)
        guard case .json(let data) = resp.body else { return XCTFail("expected json body") }
        struct Env: Decodable { let data: Info }
        struct Info: Decodable { let supported: Bool; let schemes: [String] }
        let info = try JSONDecoder().decode(Env.self, from: data).data
        #if canImport(UIKit)
        XCTAssertTrue(info.supported)
        #else
        XCTAssertFalse(info.supported, "opening URLs is unsupported without UIKit")
        #endif
    }

    func testDeepLinkOpenRejectsBadURL() async throws {
        let resp = try await runRoute(DeepLinkPlugin(), "POST", "open", json: #"{"url":"not a url"}"#)
        XCTAssertEqual(resp.status, 400)
    }

    #if !canImport(UIKit)
    func testDeepLinkOpenIs503WithoutUIKit() async throws {
        let resp = try await runRoute(DeepLinkPlugin(), "POST", "open", json: #"{"url":"myapp://x"}"#)
        XCTAssertEqual(resp.status, 503)
    }
    #endif

    // MARK: - Harness

    private func runRoute(_ plugin: any SandboxPlugin, _ method: String, _ suffix: String,
                          json: String? = nil) async throws -> SBResponse {
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
