import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

final class RouterAuthTests: XCTestCase {
    private func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "requests") { _, _ in .json(["ok": true]) },
            HTTPRoute("GET", "requests/{id}") { _, _ in .json(["ok": true]) },
            HTTPRoute("POST", "{dbId}/query") { _, _ in .json(["ok": true]) },
        ]
    }

    func testMatchesLiteralRoute() {
        let match = Router.match(method: "GET", suffix: "requests", routes: routes())
        XCTAssertNotNil(match)
        XCTAssertTrue(match?.params.isEmpty ?? false)
    }

    func testCapturesPathParameter() {
        let match = Router.match(method: "GET", suffix: "requests/42", routes: routes())
        XCTAssertEqual(match?.params["id"], "42")
    }

    func testMethodMismatchDoesNotMatch() {
        XCTAssertNil(Router.match(method: "DELETE", suffix: "requests", routes: routes()))
    }

    func testSegmentCountMismatchDoesNotMatch() {
        XCTAssertNil(Router.match(method: "GET", suffix: "requests/42/extra", routes: routes()))
    }

    func testMultiSegmentParameterRoute() {
        let match = Router.match(method: "POST", suffix: "db_3/query", routes: routes())
        XCTAssertEqual(match?.params["dbId"], "db_3")
    }

    func testAuthGateAcceptsCorrectTokenRejectsWrong() {
        let gate = AuthGate(mode: .token)
        let token = try? XCTUnwrap(gate.token)
        XCTAssertNotNil(token)
        XCTAssertTrue(gate.isAuthorized(token: token!))
        XCTAssertFalse(gate.isAuthorized(token: "definitely-wrong"))
        XCTAssertFalse(gate.isAuthorized(token: nil))
    }

    func testAuthGateNoneModeAllowsAll() {
        let gate = AuthGate(mode: .none)
        XCTAssertNil(gate.token)
        XCTAssertTrue(gate.isAuthorized(token: nil))
    }

    func testExtractTokenFromHeaderAndQuery() {
        XCTAssertEqual(AuthGate.extractToken(header: "Bearer abc123", query: [:]), "abc123")
        XCTAssertEqual(AuthGate.extractToken(header: nil, query: ["token": "q789"]), "q789")
        XCTAssertNil(AuthGate.extractToken(header: nil, query: [:]))
    }
}
#endif
