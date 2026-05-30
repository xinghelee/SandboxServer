import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// Unit tests for the App Bundle / IPA payload inspector: the hand-rolled Mach-O parser, the
/// mobileprovision plist extraction, binary-plist decoding, plist→JSON conversion, and the
/// read-only-root enforcement that protects the (OS-read-only) app bundle.
final class BundleInspectorTests: XCTestCase {

    // MARK: - Mach-O

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    private func writeTemp(_ bytes: [UInt8]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macho-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    func testParsesRealHostBinary() throws {
        // The running host binary is a real Mach-O (often fat). Whether slices are in-bounds or the
        // host is a thinned stub, we should report at least the declared architecture, recognized,
        // and never FairPlay-encrypted for a dev/test build.
        let info = MachOInspector.inspect(Bundle.main.executableURL)
        XCTAssertTrue(info.supported, "the running host binary should parse to at least one arch")
        XCTAssertGreaterThanOrEqual(info.slices.count, 1)
        XCTAssertFalse(info.slices.contains { $0.encrypted }, "a dev/test binary is never FairPlay-encrypted")
        XCTAssertTrue(info.slices.allSatisfy { !$0.cpuType.hasPrefix("cputype(") }, "cpu type should be recognized")
    }

    func testThinEncryptedSliceCryptIdAtCorrectOffset() throws {
        // Hand-built thin arm64e MH_MAGIC_64 with one LC_ENCRYPTION_INFO_64 (cryptid=1). This pins the
        // cryptid field offset (16 within the command) — the field that's easy to get wrong.
        var b: [UInt8] = []
        b += le32(0xFEED_FACF)   // MH_MAGIC_64
        b += le32(0x0100_000C)   // cputype arm64
        b += le32(2)             // cpusubtype arm64e
        b += le32(2)             // filetype MH_EXECUTE
        b += le32(1)             // ncmds
        b += le32(24)            // sizeofcmds (one LC_ENCRYPTION_INFO_64)
        b += le32(0)             // flags
        b += le32(0)             // reserved
        b += le32(0x2C)          // LC_ENCRYPTION_INFO_64
        b += le32(24)            // cmdsize
        b += le32(0)             // cryptoff
        b += le32(0)             // cryptsize
        b += le32(1)             // cryptid = 1
        b += le32(0)             // pad
        let url = try writeTemp(b)
        defer { try? FileManager.default.removeItem(at: url) }

        let info = MachOInspector.inspect(url)
        XCTAssertTrue(info.supported)
        XCTAssertFalse(info.fat)
        XCTAssertEqual(info.slices.count, 1)
        let slice = try XCTUnwrap(info.slices.first)
        XCTAssertEqual(slice.cpuType, "arm64")
        XCTAssertEqual(slice.cpuSubtype, "arm64e")
        XCTAssertTrue(slice.is64)
        XCTAssertTrue(slice.encrypted)
        XCTAssertEqual(slice.cryptId, 1)
    }

    func testTruncatedBinaryDegradesNotCrash() throws {
        // A valid magic but no header body → no slice, supported:false, no crash/OOB.
        let url = try writeTemp(le32(0xFEED_FACF))
        defer { try? FileManager.default.removeItem(at: url) }
        let info = MachOInspector.inspect(url)
        XCTAssertFalse(info.supported)
        XCTAssertTrue(info.slices.isEmpty)
    }

    func testFatHeaderWithAbsurdArchCountIsCappedNotCrash() throws {
        // FAT_MAGIC + nfat_arch = 0xFFFFFFFF, but no arch entries follow. Must cap + bail safely.
        var b: [UInt8] = []
        b += be32(0xCAFE_BABE)   // FAT_MAGIC (big-endian on disk)
        b += be32(0xFFFF_FFFF)   // nfat_arch absurdly large
        let url = try writeTemp(b)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = MachOInspector.inspect(url)
        XCTAssertTrue(info.fat)
        XCTAssertTrue(info.slices.isEmpty, "no arch entries present → no slices, no out-of-bounds read")
    }

    // MARK: - Provisioning

    func testProvisioningPlistExtractedFromWrappingBytes() throws {
        // A real .mobileprovision is a CMS blob with the XML plist embedded; extraction must recover
        // the plist from arbitrary leading/trailing bytes and the field mapping must hold.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Name</key><string>Team Provisioning Profile</string>
          <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
          <key>TeamName</key><string>Example Inc.</string>
          <key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
          <key>ProvisionedDevices</key><array><string>d1</string><string>d2</string></array>
          <key>Entitlements</key><dict>
            <key>application-identifier</key><string>ABCDE12345.com.example.app</string>
            <key>get-task-allow</key><true/>
          </dict>
        </dict></plist>
        """
        var blob = Data([0x30, 0x82, 0x12, 0x34, 0xDE, 0xAD]) // fake DER prefix
        blob.append(Data(xml.utf8))
        blob.append(Data([0xBE, 0xEF])) // trailing cert bytes

        XCTAssertNotNil(ProvisioningInspector.extractPlist(from: blob), "the embedded plist should be recoverable")
        let info = ProvisioningInspector.inspect(provisioningData: blob)
        XCTAssertTrue(info.present)
        XCTAssertNil(info.parseError)
        XCTAssertEqual(info.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(info.teamName, "Example Inc.")
        XCTAssertEqual(info.appId, "ABCDE12345.com.example.app")
        XCTAssertEqual(info.provisionedDeviceCount, 2)
        XCTAssertEqual(info.isDistribution, false)
        XCTAssertEqual(info.expired, false, "the 2099 expiry is in the future")
        if case .object(let ent)? = info.entitlements {
            XCTAssertEqual(ent["get-task-allow"], .bool(true), "boolean entitlements stay booleans, not 1/0")
        } else {
            XCTFail("entitlements should decode to an object")
        }
    }

    func testProvisioningBlobWithoutPlistReportsParseError() {
        let info = ProvisioningInspector.inspect(provisioningData: Data([0x00, 0x01, 0x02, 0x03]))
        XCTAssertTrue(info.present)
        XCTAssertNotNil(info.parseError)
    }

    // MARK: - Plist decode + JSON conversion

    func testDecodeBinaryPlistRoundTrips() throws {
        let dict: [String: Any] = ["s": "hi", "n": 42, "b": true, "arr": [1, 2, 3]]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p-\(UUID().uuidString).plist")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try BundleInspector.decodePlist(at: url)
        XCTAssertEqual(decoded.format, "binary")
        guard case .object(let obj) = decoded.json else { return XCTFail("expected an object") }
        XCTAssertEqual(obj["s"], .string("hi"))
        XCTAssertEqual(obj["n"], .int(42))
        XCTAssertEqual(obj["b"], .bool(true), "a boolean must not collapse to an int")
        XCTAssertEqual(obj["arr"], .array([.int(1), .int(2), .int(3)]))
    }

    func testDecodeNonPlistThrows() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("np-\(UUID().uuidString).txt")
        try Data("not a plist at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try BundleInspector.decodePlist(at: url))
    }

    // MARK: - Read-only root enforcement

    func testReadOnlyRootRefusesWriteMoveDelete() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: existing)
        let ctx = ROStubContext(roots: [root], readOnly: [root])

        let writeReq = SBRequest(method: "PUT", path: "file", query: ["path": root.appendingPathComponent("new.txt").path])
        let write = try await FilePlugin.write(writeReq, ctx)
        XCTAssertEqual(write.status, 403, "writing into a read-only root must be refused")

        let delReq = SBRequest(method: "DELETE", path: "file", query: ["path": existing.path])
        XCTAssertEqual(FilePlugin.delete(delReq, ctx).status, 403)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path), "the file must NOT have been deleted")
    }

    /// PluginContext stub that marks its root read-only.
    private final class ROStubContext: PluginContext, @unchecked Sendable {
        let rootURLs: [URL]; let roURLs: [URL]
        init(roots: [URL], readOnly: [URL]) { rootURLs = roots; roURLs = readOnly }
        func publish<T: Encodable & Sendable>(channel: WSChannel, type: String, payload: T) async {}
        func extraRoots() -> [URL] { rootURLs }
        func readOnlyRoots() -> [URL] { roURLs }
        func hostValue<Value>(_ key: HostValueKey<Value>) -> Value? { nil }
        var config: SandboxConfig { SandboxConfig() }
        func log(_ message: @autoclosure () -> String) {}
    }
}
#endif
