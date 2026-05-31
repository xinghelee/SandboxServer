import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// DefaultsPlugin: property-list ↔ JSON classification + a set/get/list/delete round-trip
/// against an isolated UserDefaults suite.
final class DefaultsPluginTests: XCTestCase {

    // MARK: - Value classification

    func testDescribeDistinguishesBoolIntDouble() {
        // The subtle one: NSNumber bools must not be reported as ints.
        XCTAssertEqual(DefaultsPlugin.describe(true).0, "bool")
        XCTAssertEqual(DefaultsPlugin.describe(true).1, .bool(true))
        XCTAssertEqual(DefaultsPlugin.describe(42).0, "int")
        XCTAssertEqual(DefaultsPlugin.describe(42).1, .int(42))
        XCTAssertEqual(DefaultsPlugin.describe(3.5).0, "double")
        XCTAssertEqual(DefaultsPlugin.describe("hi").1, .string("hi"))
    }

    func testDescribeArrayAndDict() {
        XCTAssertEqual(DefaultsPlugin.describe([1, 2]).1, .array([.int(1), .int(2)]))
        let (type, json) = DefaultsPlugin.describe(["k": "v"])
        XCTAssertEqual(type, "dict")
        XCTAssertEqual(json, .object(["k": .string("v")]))
    }

    func testPlistValueCoercesViaTypeHint() {
        XCTAssertEqual(DefaultsPlugin.plistValue(from: .string("42"), type: "int") as? Int, 42)
        XCTAssertEqual(DefaultsPlugin.plistValue(from: .string("3.5"), type: "double") as? Double, 3.5)
        XCTAssertEqual(DefaultsPlugin.plistValue(from: .string("YES"), type: "bool") as? Bool, true)
        XCTAssertEqual(DefaultsPlugin.plistValue(from: .string("42"), type: nil) as? String, "42")
        XCTAssertEqual(DefaultsPlugin.plistValue(from: .bool(true), type: nil) as? Bool, true)
    }

    // MARK: - Route round-trip on an isolated suite

    func testSetGetDeleteRoundTrip() async throws {
        let suite = "sbx-defaults-test-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        let plugin = DefaultsPlugin()

        // PUT a string and a bool.
        _ = try await put(plugin, json: #"{"key":"flag","value":true,"suite":"\#(suite)"}"#)
        _ = try await put(plugin, json: #"{"key":"name","value":"Ada","suite":"\#(suite)"}"#)

        XCTAssertEqual(store.bool(forKey: "flag"), true)
        XCTAssertEqual(store.string(forKey: "name"), "Ada")

        // GET one value, decoding the {data} envelope.
        let entry: Entry = try await getJSON(plugin, "value", query: ["key": "name", "suite": suite])
        XCTAssertEqual(entry.key, "name")
        XCTAssertEqual(entry.type, "string")
        XCTAssertEqual(entry.value, .string("Ada"))

        // DELETE it; the store no longer has it.
        _ = try await run(plugin, "DELETE", "value", query: ["key": "name", "suite": suite])
        XCTAssertNil(store.object(forKey: "name"))

        // GET the deleted key → 404.
        let resp = try await run(plugin, "GET", "value", query: ["key": "name", "suite": suite])
        XCTAssertEqual(resp.status, 404)
    }

    func testSetNullDeletesKey() async throws {
        let suite = "sbx-defaults-test-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set("present", forKey: "k")

        let plugin = DefaultsPlugin()
        _ = try await put(plugin, json: #"{"key":"k","value":null,"suite":"\#(suite)"}"#)
        XCTAssertNil(store.object(forKey: "k"), "setting a null value should remove the key")
    }

    func testListAppScopeReturnsSuiteKeys() async throws {
        let suite = "sbx-defaults-test-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(1, forKey: "z_alpha")
        store.set(2, forKey: "z_beta")

        let plugin = DefaultsPlugin()
        let listing: Listing = try await getJSON(plugin, "", query: ["suite": suite, "prefix": "z_"])
        let keys = Set(listing.items.map(\.key))
        XCTAssertTrue(keys.isSuperset(of: ["z_alpha", "z_beta"]), "got \(keys)")
        XCTAssertEqual(listing.scope, "app")
        // Sorted ascending by key.
        XCTAssertEqual(listing.items.map(\.key), listing.items.map(\.key).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testMissingKeyIs400() async throws {
        let resp = try await run(DefaultsPlugin(), "GET", "value", query: [:])
        XCTAssertEqual(resp.status, 400)
    }

    // MARK: - Decodable mirrors of the plugin's payload shapes

    private struct Entry: Decodable { let key: String; let type: String; let value: JSONValue; let preview: String }
    private struct Listing: Decodable { let suite: String?; let scope: String; let count: Int; let items: [Entry] }
    private struct Env<T: Decodable>: Decodable { let data: T }

    // MARK: - Route harness

    private func route(_ plugin: DefaultsPlugin, _ method: String, _ suffix: String) throws -> HTTPRoute {
        try XCTUnwrap(plugin.routes().first { $0.method == method && $0.pathSuffix == suffix })
    }

    @discardableResult
    private func run(_ plugin: DefaultsPlugin, _ method: String, _ suffix: String,
                     query: [String: String] = [:], json: String? = nil) async throws -> SBResponse {
        let r = try route(plugin, method, suffix)
        let body = json.map { Data($0.utf8) }
        let req = SBRequest(method: method, path: suffix, query: query, body: {
            AsyncThrowingStream { cont in
                if let body { cont.yield(ArraySlice(body)) }
                cont.finish()
            }
        })
        return try await r.handler(req, StubCtx())
    }

    @discardableResult
    private func put(_ plugin: DefaultsPlugin, json: String) async throws -> SBResponse {
        try await run(plugin, "PUT", "value", json: json)
    }

    private func getJSON<T: Decodable>(_ plugin: DefaultsPlugin, _ suffix: String, query: [String: String]) async throws -> T {
        let resp = try await run(plugin, "GET", suffix, query: query)
        XCTAssertEqual(resp.status, 200)
        guard case .json(let data) = resp.body else { throw XCTSkip("expected json body") }
        return try JSONDecoder().decode(Env<T>.self, from: data).data
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
