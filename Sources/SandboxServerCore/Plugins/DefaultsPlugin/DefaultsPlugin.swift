import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE. Inspects and edits `UserDefaults`. Browse the app's own persisted defaults (the
/// persistent domain for the bundle id), an App Group / custom suite, or — with `?scope=all` —
/// the full resolved dictionary (including inherited global + registration domains). Set or
/// delete individual keys, or reset a whole domain. All public API, safe on every platform.
///
/// Routes:
///   GET    ""        list defaults  (?scope=app|all, ?suite=<name>, ?prefix=<str>)
///   GET    value     read one key   (?key=<k>, ?suite=<name>)
///   PUT    value     set a key      { key, value, type?, suite? }
///   DELETE value     remove a key   (?key=<k>, ?suite=<name>)
///   POST   reset     wipe a domain  { suite? }   ← destructive
struct DefaultsPlugin: SandboxPlugin {
    let id = PluginID.defaults

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Defaults", panelKey: "defaults",
            routes: ["GET (list)", "GET value", "PUT value", "DELETE value", "POST reset"],
            channels: [],
            mcpTools: [
                .init(name: "defaults_list", title: "List UserDefaults",
                      description: "List UserDefaults entries with key, type, and value. scope=app (default, the app's own persisted keys) or scope=all (full resolved dictionary incl. global/registration domains). Optional suite (App Group / custom suite name) and prefix filter.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "defaults_get", title: "Get a default",
                      description: "Read a single UserDefaults key. Optional suite (App Group / custom suite name).",
                      backingMethod: "GET", backingPathSuffix: "value", readOnlyHint: true, destructiveHint: false),
                .init(name: "defaults_set", title: "Set a default",
                      description: "Set a UserDefaults key. value is a JSON value (string/number/bool/array/object); pass type=int|double|bool|string to coerce a string value. Optional suite.",
                      backingMethod: "PUT", backingPathSuffix: "value", readOnlyHint: false, destructiveHint: false),
                .init(name: "defaults_delete", title: "Delete a default",
                      description: "Remove a single UserDefaults key. Optional suite.",
                      backingMethod: "DELETE", backingPathSuffix: "value", readOnlyHint: false, destructiveHint: true),
                .init(name: "defaults_reset", title: "Reset a domain",
                      description: "Remove ALL keys in a persistent domain (the app itself, or a named suite). Destructive — wipes every default in that domain.",
                      backingMethod: "POST", backingPathSuffix: "reset", readOnlyHint: false, destructiveHint: true),
            ],
            limitations: [
                "Edits target NSUserDefaults; values are property-list types. Date/Data values are shown (ISO-8601 / base64) but editing is limited to string/number/bool/array/object.",
                "scope=app lists the bundle-id persistent domain; some frameworks register transient defaults that only appear under scope=all.",
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { req, _ in
                let suite = req.query["suite"]
                guard let store = DefaultsPlugin.store(for: suite) else { return DefaultsPlugin.badSuite(suite) }
                let scopeAll = req.query["scope"] == "all"
                let dict: [String: Any]
                if scopeAll {
                    dict = store.dictionaryRepresentation()
                } else if let domain = DefaultsPlugin.appDomain(suite) {
                    dict = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
                } else {
                    // No app persistent domain (e.g. a CLI host with no bundle id) — fall back to
                    // the full dictionary so scope=app still shows the keys that were set.
                    dict = store.dictionaryRepresentation()
                }
                let prefix = req.query["prefix"]
                let entries = dict
                    .filter { prefix == nil || $0.key.hasPrefix(prefix!) }
                    .map { DefaultsPlugin.entry(key: $0.key, value: $0.value) }
                    .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                return .json(Listing(suite: suite, scope: scopeAll ? "all" : "app", count: entries.count, items: entries))
            },

            HTTPRoute("GET", "value", annotations: .read) { req, _ in
                guard let key = req.query["key"], !key.isEmpty else { return DefaultsPlugin.missingKey() }
                let suite = req.query["suite"]
                guard let store = DefaultsPlugin.store(for: suite) else { return DefaultsPlugin.badSuite(suite) }
                guard let value = store.object(forKey: key) else {
                    return .error("not_found", "No UserDefaults value for key '\(key)'.", status: 404)
                }
                return .json(DefaultsPlugin.entry(key: key, value: value))
            },

            HTTPRoute("PUT", "value", annotations: .write) { req, _ in
                struct Body: Decodable { let key: String; let value: JSONValue; let type: String?; let suite: String? }
                guard let body = try? await req.decodeJSON(Body.self), !body.key.isEmpty else {
                    return .error("bad_request", "Expected JSON { key, value, type?, suite? }.", status: 400)
                }
                guard let store = DefaultsPlugin.store(for: body.suite) else { return DefaultsPlugin.badSuite(body.suite) }
                if case .null = body.value {
                    store.removeObject(forKey: body.key)
                } else {
                    store.set(DefaultsPlugin.plistValue(from: body.value, type: body.type), forKey: body.key)
                }
                let stored = store.object(forKey: body.key)
                return .json(stored.map { DefaultsPlugin.entry(key: body.key, value: $0) }
                    ?? Entry(key: body.key, type: "null", value: .null, preview: "nil"))
            },

            HTTPRoute("DELETE", "value", annotations: .destructive) { req, _ in
                guard let key = req.query["key"], !key.isEmpty else { return DefaultsPlugin.missingKey() }
                let suite = req.query["suite"]
                guard let store = DefaultsPlugin.store(for: suite) else { return DefaultsPlugin.badSuite(suite) }
                store.removeObject(forKey: key)
                return .json(Deleted(key: key, deleted: true))
            },

            HTTPRoute("POST", "reset", annotations: .destructive) { req, _ in
                struct Body: Decodable { let suite: String? }
                let body = try? await req.decodeJSON(Body.self)
                let suite = body?.suite
                guard let store = DefaultsPlugin.store(for: suite) else { return DefaultsPlugin.badSuite(suite) }
                store.removePersistentDomain(forName: DefaultsPlugin.domainName(suite))
                return .json(Reset(domain: DefaultsPlugin.domainName(suite), reset: true))
            },
        ]
    }

    // MARK: - Payload shapes

    struct Entry: Encodable, Sendable {
        let key: String
        let type: String
        let value: JSONValue
        /// A short, one-line human rendering for the console list.
        let preview: String
    }
    struct Listing: Encodable, Sendable {
        let suite: String?
        let scope: String
        let count: Int
        let items: [Entry]
    }
    struct Deleted: Encodable, Sendable { let key: String; let deleted: Bool }
    struct Reset: Encodable, Sendable { let domain: String; let reset: Bool }

    // MARK: - Suite / domain resolution

    /// The defaults store to operate on. `nil` suite → `.standard`; a named suite must init cleanly
    /// (it returns nil for the bundle-id name or an invalid name), in which case we report a 400.
    private static func store(for suite: String?) -> UserDefaults? {
        guard let suite, !suite.isEmpty else { return .standard }
        if suite == Bundle.main.bundleIdentifier { return .standard }
        return UserDefaults(suiteName: suite)
    }

    /// The persistent-domain name for `reset` (always concrete — falls back to "Global" when the
    /// host has no bundle id, so a reset is still a no-op rather than a crash).
    private static func domainName(_ suite: String?) -> String {
        appDomain(suite) ?? "Global"
    }

    /// The app's persistent-domain name for `?scope=app` listing: an explicit suite, otherwise the
    /// bundle id. `nil` when neither exists (a CLI/test host) — the caller then lists the full dict.
    private static func appDomain(_ suite: String?) -> String? {
        if let suite, !suite.isEmpty, suite != Bundle.main.bundleIdentifier { return suite }
        return Bundle.main.bundleIdentifier
    }

    private static func badSuite(_ suite: String?) -> SBResponse {
        .error("bad_suite", "Could not open UserDefaults suite '\(suite ?? "")'.", status: 400)
    }
    private static func missingKey() -> SBResponse {
        .error("bad_request", "Query parameter 'key' is required.", status: 400)
    }

    // MARK: - Value <-> JSON conversion

    /// Classify a property-list value into a type label + JSON rendering + a short preview.
    static func entry(key: String, value: Any) -> Entry {
        let (type, json) = describe(value)
        return Entry(key: key, type: type, value: json, preview: preview(type: type, json: json))
    }

    static func describe(_ value: Any) -> (String, JSONValue) {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return ("bool", .bool(n.boolValue)) }
            let d = n.doubleValue
            if d.rounded() == d && abs(d) < 9_007_199_254_740_992 { return ("int", .int(n.intValue)) }
            return ("double", .double(d))
        case let s as String:
            return ("string", .string(s))
        case let date as Date:
            return ("date", .string(ISO8601DateFormatter().string(from: date)))
        case let data as Data:
            return ("data", .string(data.base64EncodedString()))
        case let arr as [Any]:
            return ("array", .array(arr.map { describe($0).1 }))
        case let dict as [String: Any]:
            return ("dict", .object(dict.mapValues { describe($0).1 }))
        case is NSNull:
            return ("null", .null)
        default:
            return ("unknown", .string(String(describing: value)))
        }
    }

    /// Convert an incoming JSON value into a property-list value to store. `type` optionally
    /// coerces a JSON string into a primitive (so `defaults_set key=x value="42" type=int` works).
    static func plistValue(from json: JSONValue, type: String?) -> Any {
        switch json {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s):
            switch type {
            case "int": return Int(s) ?? s
            case "double": return Double(s) ?? s
            case "bool": return (s as NSString).boolValue
            default: return s
            }
        case .array(let a): return a.map { plistValue(from: $0, type: nil) }
        case .object(let o): return o.mapValues { plistValue(from: $0, type: nil) }
        }
    }

    private static func preview(type: String, json: JSONValue) -> String {
        switch json {
        case .null: return "nil"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s.count > 120 ? String(s.prefix(120)) + "…" : s
        case .array(let a): return "[\(a.count) items]"
        case .object(let o): return "{\(o.count) keys}"
        }
    }
}
