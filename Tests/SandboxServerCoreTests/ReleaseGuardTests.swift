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
        // dev / ad-hoc (provisioning present) → allowed, regardless of the receipt name
        XCTAssertTrue(allowed(ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: false, hasProvisioning: true)))
        // Xcode debug build on a device carries a `sandboxReceipt` AND provisioning — must still be
        // allowed (the regression that previously misfired as "TestFlight").
        XCTAssertTrue(allowed(ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: true, hasProvisioning: true)))
        // App Store (provisioning stripped, production receipt) → refused
        XCTAssertFalse(allowed(ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: false, hasProvisioning: false)))
        // TestFlight (provisioning stripped, sandboxReceipt) → refused with the TestFlight reason
        guard case .refused(let reason) = ReleaseGuard.evaluate(isRealAppleDevice: true, isTestFlight: true, hasProvisioning: false) else {
            return XCTFail("must refuse")
        }
        XCTAssertTrue(reason.contains("TestFlight"), "stripped provisioning + sandboxReceipt is TestFlight")
    }

    func testVerifyAllowsOnTheTestHost() {
        // The macOS/simulator test host must always be allowed so dev + CI can boot the server.
        XCTAssertTrue(allowed(ReleaseGuard.verify()))
    }
}
#endif
