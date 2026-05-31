import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// D1: the path fence (`FilePlugin.resolve`) confines every fs/db path to an allowed root — the
/// foundation of all file/DB safety, previously untested. Drives resolve() directly plus a handler
/// to confirm an out-of-bounds path is a 403.
final class FilePluginResolveTests: XCTestCase {
    private var root: URL!          // an allowed root (a temp dir)
    private var outside: URL!       // a sibling dir OUTSIDE the root

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbx-fence-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        outside = base.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("top secret".utf8).write(to: outside.appendingPathComponent("passwd"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private var ctx: StubContext { StubContext(roots: [root]) }
    /// True when `resolved` is non-nil and confined to `root`.
    private func confined(_ resolved: URL?) -> Bool {
        guard let p = resolved?.standardizedFileURL.resolvingSymlinksInPath().path else { return false }
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        return p == r || p.hasPrefix(r + "/")
    }

    func testNilEmptyAndSlashResolveToFirstRoot() {
        let first = FilePlugin.roots(ctx).first
        XCTAssertEqual(FilePlugin.resolve(nil, ctx), first)
        XCTAssertEqual(FilePlugin.resolve("", ctx), first)
        XCTAssertEqual(FilePlugin.resolve("/", ctx), first)
    }

    func testAbsolutePathOutsideRootsIsRejected() {
        XCTAssertNil(FilePlugin.resolve("/etc/passwd", ctx))
        XCTAssertNil(FilePlugin.resolve(outside.appendingPathComponent("passwd").path, ctx))
    }

    func testTraversalEscapeIsRejected() {
        // A path that climbs out of the root via `..` must not resolve.
        let escape = root.path + "/../secret/passwd"
        XCTAssertNil(FilePlugin.resolve(escape, ctx))
    }

    func testSiblingPrefixIsNotConfused() {
        // Root is `<base>/root`; a sibling `<base>/root2` must NOT be treated as inside it
        // (the trailing-slash boundary guard — /a/b must not match /a/bb).
        let sibling = root.deletingLastPathComponent().appendingPathComponent("root2/x").path
        XCTAssertNil(FilePlugin.resolve(sibling, ctx))
    }

    func testValidLeafUnderRootResolves() {
        let inside = root.appendingPathComponent("sub/file.txt").path
        XCTAssertTrue(confined(FilePlugin.resolve(inside, ctx)), "an existing-or-new leaf under the root resolves")
    }

    func testSymlinkInsideRootPointingOutsideIsRejected() throws {
        // A symlink within the root that targets outside must resolve to its target and be rejected.
        let link = root.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(FilePlugin.resolve(link.appendingPathComponent("passwd").path, ctx),
                     "a symlink escaping the root must not resolve")
    }

    func testRelativePathResolvesAgainstPrimaryRoot() {
        // A bare relative path lands under the primary (app-container) root, not the process cwd —
        // so an AI/human can pass "Documents/app.sqlite" instead of the full container path.
        let first = FilePlugin.roots(ctx).first!.resolvingSymlinksInPath().standardizedFileURL
        let resolved = FilePlugin.resolve("Documents/app.sqlite", ctx)?.standardizedFileURL.path
        XCTAssertEqual(resolved, first.appendingPathComponent("Documents/app.sqlite").standardizedFileURL.path)
    }

    func testRelativeTraversalStillRejected() {
        // Relative resolution must not become an escape hatch: `..` that climbs out is still nil.
        XCTAssertNil(FilePlugin.resolve("../../../../etc/passwd", ctx))
    }

    func testHandlerReturns403ForOutOfBoundsPath() {
        let req = SBRequest(method: "GET", path: "list", query: ["path": "/etc"])
        let resp = FilePlugin.list(req, ctx)
        XCTAssertEqual(resp.status, 403, "listing a path outside the roots must be forbidden")
    }

    /// Minimal PluginContext exposing the temp root for the fence.
    private final class StubContext: PluginContext, @unchecked Sendable {
        let rootURLs: [URL]
        init(roots: [URL]) { self.rootURLs = roots }
        func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {}
        func extraRoots() -> [URL] { rootURLs }
        func hostValue<Value>(_ key: HostValueKey<Value>) -> Value? { nil }
        var config: SandboxConfig { SandboxConfig() }
        func log(_ message: @autoclosure () -> String) {}
    }
}
#endif
