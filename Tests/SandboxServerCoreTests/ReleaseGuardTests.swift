import XCTest
#if SandboxServerEnabled
@testable import SandboxServerCore

/// D5: the production-environment refusal matrix. Tests the pure `evaluate` so the App-Store /
/// TestFlight refusal logic is covered without depending on Bundle.main.
final class ReleaseGuardTests: XCTestCase {
    private func allowed(_ v: ReleaseGuard.Verdict) -> Bool {
        if case .allowed = v { return true }
        return false
    }

    func testDevContextsAlwaysAllowed() {
        // Simulator / macOS / any non-mobile platform (isRealAppleDevice == false) always allows.
        XCTAssertTrue(allowed(ReleaseGuard.evaluate(isRealAppleDevice: false, isTestFlight: true, hasProvisioning: false)))
        XCTAssertTrue(allowed(ReleaseGuard.evaluate(isRealAppleDevice: false, isTestFlight: false, hasProvisioning: true)))
    }

    func testRealDeviceMatrix() {
        // dev / ad-hoc (provisioning present, not TestFlight) → allowed
        XCTAssertTrue(allowed(ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: false, hasProvisioning: true)))
        // App Store (provisioning stripped) → refused
        XCTAssertFalse(allowed(ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: false, hasProvisioning: false)))
        // TestFlight → refused
        XCTAssertFalse(allowed(ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: true, hasProvisioning: true)))
        // TestFlight is checked before the App-Store case
        guard case .refused(let reason) = ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: true, hasProvisioning: false) else {
            return XCTFail("must refuse")
        }
        XCTAssertTrue(reason.contains("TestFlight"), "TestFlight takes precedence over the App-Store reason")
    }

    func testVerifyAllowsOnTheTestHost() {
        // The macOS/simulator test host must always be allowed so dev + CI can boot the server.
        XCTAssertTrue(allowed(ReleaseGuard.verify()))
    }
}
#endif
