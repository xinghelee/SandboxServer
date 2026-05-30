import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Runs the auth gate and a DNS-rebinding guard *before* any plugin sees a request, so a
/// newly-added plugin can never accidentally expose an unauthenticated or rebindable route.
struct MiddlewareChain: Sendable {
    let auth: AuthGate
    let bindingPolicy: BindingPolicy

    /// Returns a rejection response, or `nil` to proceed. Static console assets pass
    /// `requiresAuth: false` so the browser can load before optional `?token=` bootstrap happens.
    func reject(_ head: HTTPRequestHead, requiresAuth: Bool) -> SBResponse? {
        if let hostRejection = validateHost(head) { return hostRejection }
        if requiresAuth {
            let presented = AuthGate.extractToken(header: head.header("authorization"), query: head.query)
            if !auth.isAuthorized(token: presented) {
                return .error("unauthorized", "Missing or invalid session token.", status: 401)
            }
        }
        return nil
    }

    /// DNS-rebinding mitigation: the `Host` header must be a literal IP or `localhost`,
    /// never an attacker-controlled domain that resolves to the device.
    private func validateHost(_ head: HTTPRequestHead) -> SBResponse? {
        guard let host = head.header("host") else { return nil } // tolerate absent Host (curl/HTTP1.0)
        let name = hostname(stripPort: host)
        if name == "localhost" || isIPLiteral(name) { return nil }
        return .error("bad_host", "Rejected Host header '\(host)' (possible DNS rebinding).", status: 403)
    }

    private func hostname(stripPort host: String) -> String {
        if host.hasPrefix("[") { // bracketed IPv6, e.g. [::1]:8080
            if let close = host.firstIndex(of: "]") { return String(host[host.index(after: host.startIndex)..<close]) }
        }
        return String(host.split(separator: ":").first ?? Substring(host))
    }

    private func isIPLiteral(_ s: String) -> Bool {
        if s.contains(":") { // IPv6
            return s.allSatisfy { $0.isHexDigit || $0 == ":" }
        }
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }
}
