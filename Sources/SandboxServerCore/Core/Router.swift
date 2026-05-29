import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// A route matched against a request, with its captured path parameters.
struct RouteMatch {
    let route: HTTPRoute
    let params: [String: String]
}

/// Stateless path matcher. Patterns may contain `{name}` segments captured into `params`.
enum Router {
    /// The reserved API prefix all REST + WS endpoints live under.
    static let apiPrefix = "/__sandbox/api/v1"
    static let wsPath = "/__sandbox/ws"

    /// Matches `suffix` (the path relative to a plugin's mount prefix) against `routes`.
    static func match(method: String, suffix: String, routes: [HTTPRoute]) -> RouteMatch? {
        let requestSegments = segments(suffix)
        let upperMethod = method.uppercased()
        for route in routes where route.method == upperMethod {
            let patternSegments = segments(route.pathSuffix)
            guard patternSegments.count == requestSegments.count else { continue }
            var params: [String: String] = [:]
            var matched = true
            for (pattern, value) in zip(patternSegments, requestSegments) {
                if pattern.hasPrefix("{"), pattern.hasSuffix("}") {
                    params[String(pattern.dropFirst().dropLast())] = value.removingPercentEncoding ?? value
                } else if pattern != value {
                    matched = false
                    break
                }
            }
            if matched { return RouteMatch(route: route, params: params) }
        }
        return nil
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
