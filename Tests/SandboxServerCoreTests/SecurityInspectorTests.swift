import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// Unit tests for the static security/hardening grader: scoring, grade banding, the get-task-allow
/// (debuggable) check from provisioning entitlements, and graceful handling of unknown facts.
final class SecurityInspectorTests: XCTestCase {

    private func slice(
        pie: Bool? = true, canary: Bool? = true, arc: Bool? = true,
        codeSig: Bool? = true, encrypted: Bool = false
    ) -> MachOInspector.Slice {
        MachOInspector.Slice(
            cpuType: "arm64", cpuSubtype: "arm64e", is64: true, magic: "MH_MAGIC_64",
            encrypted: encrypted, cryptId: encrypted ? 1 : 0, fileType: "execute",
            pie: pie, stackCanary: canary, arc: arc, codeSignature: codeSig, restrict: nil)
    }

    private func macho(_ s: MachOInspector.Slice) -> MachOInspector.Info {
        MachOInspector.Info(supported: true, executablePath: "/x", fileSize: 1000, fat: false, slices: [s])
    }

    private func prov(getTaskAllow: Bool?) -> ProvisioningInspector.Info {
        var info = ProvisioningInspector.Info.absent()
        if let v = getTaskAllow {
            info = ProvisioningInspector.Info(
                present: true, name: nil, teamIdentifier: nil, teamName: nil, appIdName: nil,
                appId: nil, creationDate: nil, expirationDate: nil, expired: nil,
                provisionedDeviceCount: nil, isDistribution: nil,
                entitlements: .object(["get-task-allow": .bool(v)]), parseError: nil)
        }
        return info
    }

    func testFullyHardenedReleaseScoresA() {
        // All mitigations on, not debuggable → 100 / A.
        let r = SecurityInspector.evaluate(macho: macho(slice()), provisioning: prov(getTaskAllow: false))
        XCTAssertTrue(r.supported)
        XCTAssertEqual(r.score, 100)
        XCTAssertEqual(r.grade, "A")
        XCTAssertEqual(r.arch, "arm64 arm64e")
    }

    func testDebuggableNoPieScoresLow() {
        // No PIE (-25), debuggable get-task-allow=true (-25) → 50/100 → grade C.
        let r = SecurityInspector.evaluate(
            macho: macho(slice(pie: false)), provisioning: prov(getTaskAllow: true))
        XCTAssertEqual(r.score, 50)
        XCTAssertEqual(r.grade, "C")
        // The two failing checks are reported as fail.
        XCTAssertEqual(r.checks.first { $0.id == "pie" }?.status, "fail")
        XCTAssertEqual(r.checks.first { $0.id == "getTaskAllow" }?.status, "fail")
    }

    func testUnknownChecksAreExcludedFromDenominator() {
        // No provisioning (get-task-allow unknown) and unknown canary/arc: only the resolvable
        // weighted checks count. With pie+codeSig pass (25+15) and nothing failing, score = 100.
        let s = slice(pie: true, canary: nil, arc: nil, codeSig: true)
        let r = SecurityInspector.evaluate(macho: macho(s), provisioning: prov(getTaskAllow: nil))
        XCTAssertEqual(r.checks.first { $0.id == "getTaskAllow" }?.status, "unknown")
        XCTAssertEqual(r.checks.first { $0.id == "stackCanary" }?.status, "unknown")
        XCTAssertEqual(r.score, 100, "unknown checks must not lower the score")
        XCTAssertEqual(r.grade, "A")
    }

    func testEncryptionIsInformationalNotScored() {
        let r = SecurityInspector.evaluate(macho: macho(slice(encrypted: true)), provisioning: prov(getTaskAllow: false))
        let enc = r.checks.first { $0.id == "encryption" }
        XCTAssertEqual(enc?.status, "info")
        XCTAssertEqual(enc?.weight, 0)
        XCTAssertEqual(r.score, 100, "an info check never changes the score")
    }

    func testUnsupportedMachOYieldsEmptyReport() {
        let empty = MachOInspector.Info(supported: false, executablePath: nil, fileSize: 0, fat: false, slices: [])
        let r = SecurityInspector.evaluate(macho: empty, provisioning: prov(getTaskAllow: nil))
        XCTAssertFalse(r.supported)
        XCTAssertEqual(r.grade, "—")
        XCTAssertTrue(r.checks.isEmpty)
    }
}
#endif
