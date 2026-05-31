import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE (iOS). A deep-link / URL-scheme trigger. Lists the URL schemes the app declares in its
/// Info.plist (`CFBundleURLTypes`) and opens a URL — a custom scheme or a universal/https link —
/// in the host app via `UIApplication.open`, so a tester (or an AI client) can fire deep links
/// without typing them on the device. `UIApplication.open` is public API. Reports
/// `supported: false` on a non-UIKit host, where opening URLs in-process is not available.
///
/// Routes:
///   GET  ""     → { supported, schemes, urlTypes }
///   POST open   → { url }   opens the URL; returns { url, accepted }
struct DeepLinkPlugin: SandboxPlugin {
    let id = PluginID.deeplink

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Deep Links", panelKey: "deeplink",
            routes: ["GET (schemes)", "POST open"],
            channels: [],
            mcpTools: [
                .init(name: "deeplink_list_schemes", title: "List URL schemes",
                      description: "List the URL schemes the app declares in its Info.plist (CFBundleURLTypes), plus whether opening URLs in-process is supported on this host.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "deeplink_open", title: "Open a URL",
                      description: "Open a URL in the host app — a custom scheme (e.g. myapp://path) or a universal/https link. Drives UIApplication.open; returns whether the system accepted it.",
                      backingMethod: "POST", backingPathSuffix: "open", readOnlyHint: false, destructiveHint: false),
            ],
            limitations: [
                "Opening URLs requires UIKit (iOS); on a non-UIKit host this reports supported: false and POST open returns 503.",
                "`accepted` reflects whether the system could open the URL, not whether the app finished handling it. Universal links may bounce to Safari if associated-domains aren't set up.",
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { _, _ in
                .json(Info(supported: DeepLinkPlugin.supported, schemes: DeepLinkPlugin.declaredSchemes(), urlTypes: DeepLinkPlugin.declaredURLTypes()))
            },

            HTTPRoute("POST", "open", annotations: .write) { req, _ in
                struct Body: Decodable { let url: String }
                guard let body = try? await req.decodeJSON(Body.self),
                      let url = URL(string: body.url.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme != nil else {
                    return .error("bad_request", "Expected JSON { url } with a valid absolute URL (incl. scheme).", status: 400)
                }
                #if canImport(UIKit)
                let accepted = await DeepLinkPlugin.open(url)
                return .json(Opened(url: url.absoluteString, accepted: accepted))
                #else
                return .error("unsupported", "Opening URLs requires UIKit (iOS).", status: 503)
                #endif
            },
        ]
    }

    // MARK: - Payload shapes

    struct URLTypeInfo: Encodable, Sendable {
        let name: String?
        let role: String?
        let schemes: [String]
    }
    struct Info: Encodable, Sendable {
        let supported: Bool
        let schemes: [String]
        let urlTypes: [URLTypeInfo]
    }
    struct Opened: Encodable, Sendable { let url: String; let accepted: Bool }

    // MARK: - Bundle introspection (all platforms)

    static var supported: Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    static func declaredURLTypes() -> [URLTypeInfo] {
        guard let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return types.map {
            URLTypeInfo(
                name: $0["CFBundleURLName"] as? String,
                role: $0["CFBundleTypeRole"] as? String,
                schemes: ($0["CFBundleURLSchemes"] as? [String]) ?? []
            )
        }
    }

    static func declaredSchemes() -> [String] {
        var seen = Set<String>()
        return declaredURLTypes().flatMap { $0.schemes }.filter { seen.insert($0).inserted }
    }

    #if canImport(UIKit)
    // We always attempt the open rather than gating on canOpenURL — that query is restricted by
    // LSApplicationQueriesSchemes and would wrongly reject the app's own declared schemes.
    @MainActor
    private static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { cont in
            UIApplication.shared.open(url, options: [:]) { cont.resume(returning: $0) }
        }
    }
    #endif
}
