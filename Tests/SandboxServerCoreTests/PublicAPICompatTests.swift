import XCTest
import SandboxServerAPI
import SandboxServerNoOp
#if SandboxServerEnabled
import SandboxServerCore

/// Guards the core invariant of the dual-product design: the real engine and the no-op stub
/// expose the *same* public surface (`SandboxServerEngine`), so the facade compiles unchanged
/// against either. If a method is added to one and not the other, this stops compiling.
final class PublicAPICompatTests: XCTestCase {
    func testBothEnginesConformToTheSameAPI() {
        let core: any SandboxServerEngine = SandboxServerCore()
        let noop: any SandboxServerEngine = SandboxServerNoOp()
        XCTAssertFalse(core.isRunning)
        XCTAssertFalse(noop.isRunning)
    }

    func testNoOpStartReturnsDisabled() async {
        let noop = SandboxServerNoOp()
        let result = await noop.start(.default)
        guard case .disabled = result else { return XCTFail("no-op start must return .disabled") }
    }
}
#endif
