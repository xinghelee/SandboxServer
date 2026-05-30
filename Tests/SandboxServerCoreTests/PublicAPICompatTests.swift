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

    /// Exercises EVERY `SandboxServerEngine` member through the protocol on BOTH engines. If a
    /// public method is added to one engine without the protocol (and thus the other), this stops
    /// compiling — guarding the load-bearing dual-product invariant against *additive* drift.
    func testFullEngineSurfaceMatchesOnBothEngines() async {
        func exercise(_ engine: any SandboxServerEngine) async -> StartResult {
            engine.register(CompatTestPlugin())
            engine.setHostValue("v", for: HostValueKey<String>("compat.key"))
            engine.addRoot(URL(fileURLWithPath: NSTemporaryDirectory()))
            engine.log("compat", level: "info", category: "test")
            let result = await engine.start(SandboxConfig(bindingPolicy: .loopback, builtInPlugins: .none, preferredPort: 0))
            _ = engine.isRunning
            await engine.stop()
            return result
        }

        switch await exercise(SandboxServerCore()) {
        case .started, .failed: break // the real engine boots (or refuses) — never "disabled"
        case .disabled: XCTFail("the real core must not report .disabled")
        }
        guard case .disabled = await exercise(SandboxServerNoOp()) else {
            return XCTFail("the no-op engine must report .disabled")
        }
    }
}

/// A do-nothing plugin so the compat test can call register() through the protocol.
private struct CompatTestPlugin: SandboxPlugin {
    let id = PluginID("compat-test")
    var capabilities: PluginCapabilities {
        PluginCapabilities(id: id.rawValue, version: "1.0.0", title: "Compat", panelKey: "compat")
    }
    func routes() -> [HTTPRoute] { [] }
}
#endif
