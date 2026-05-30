import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// D5: the DNS-rebinding Host guard runs before any plugin, and the AuthGate locks out after too
/// many failures. Drives the guard through MiddlewareChain.reject (validateHost is private).
final class MiddlewareHostTests: XCTestCase {
    private func head(host: String?, authorization: String? = nil) -> HTTPRequestHead {
        var headers: [String: String] = [:]
        if let host { headers["host"] = host }
        if let authorization { headers["authorization"] = authorization }
        return HTTPRequestHead(method: "GET", target: "/x", version: "HTTP/1.1", headers: headers)
    }

    private func chain(_ mode: AuthMode = .none) -> MiddlewareChain {
        MiddlewareChain(auth: AuthGate(mode: mode), bindingPolicy: .loopback)
    }

    func testLegalHostsPass() {
        let c = chain()
        let legal: [String?] = [nil, "localhost", "127.0.0.1", "127.0.0.1:8080", "192.168.1.1",
                                "[::1]", "[::1]:8080", "[2001:db8::1]"]
        for host in legal {
            XCTAssertNil(c.reject(head(host: host), requiresAuth: false), "host \(host ?? "<nil>") should pass")
        }
    }

    func testIllegalHostsRejectedWith403() {
        let c = chain()
        for host in ["attacker.com", "evil.example.com", "192.168.1.256"] {
            XCTAssertEqual(c.reject(head(host: host), requiresAuth: false)?.status, 403, "host \(host) should be rejected")
        }
    }

    func testHostCheckedBeforeToken() {
        // A bad Host with auth required must be a 403 (bad_host), not a 401 — host is validated first.
        let resp = chain(.token).reject(head(host: "attacker.com"), requiresAuth: true)
        XCTAssertEqual(resp?.status, 403, "the host rejection precedes the token check")
    }

    func testAuthGateLocksOutAfterTooManyFailures() {
        let gate = AuthGate(mode: .token)
        let correct = gate.token
        XCTAssertNotNil(correct)
        XCTAssertTrue(gate.isAuthorized(token: correct), "the freshly minted token authorizes")
        for _ in 0..<20 { XCTAssertFalse(gate.isAuthorized(token: "WRONG-TOKEN")) }
        XCTAssertFalse(gate.isAuthorized(token: correct),
                       "after 20 failures the gate is locked — even the correct token is refused")
    }
}
#endif
