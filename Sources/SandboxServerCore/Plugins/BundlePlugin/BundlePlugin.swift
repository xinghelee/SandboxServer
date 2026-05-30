import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Inspects the running app bundle — the installed, unpacked form of the IPA's `Payload/App.app`.
/// Surfaces the Info.plist summary, the main executable's Mach-O architectures + FairPlay encryption
/// status, the embedded provisioning profile + entitlements, declared privacy/permissions, and a
/// binary-plist → readable-JSON decode route. The raw bundle tree itself is browsable through the
/// `fs` plugin: when `BuiltInPlugins.appBundle` is set, the core registers `Bundle.main.bundleURL`
/// as a READ-ONLY root. All routes degrade gracefully on a non-app host.
struct BundlePlugin: SandboxPlugin {
    let id = PluginID.bundle

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Bundle", panelKey: "bundle",
            routes: ["GET (summary)", "GET macho", "GET provisioning", "GET privacy", "GET plist"],
            mcpTools: [
                .init(name: "bundle_summary", title: "Bundle summary",
                      description: "App bundle identity: bundle id, name, version/build, minimum OS, device families, icon.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "bundle_macho", title: "Mach-O info",
                      description: "CPU architectures of the main executable and whether each slice is FairPlay-encrypted (cryptid).",
                      backingMethod: "GET", backingPathSuffix: "macho", readOnlyHint: true, destructiveHint: false),
                .init(name: "bundle_provisioning", title: "Provisioning profile",
                      description: "embedded.mobileprovision: team, app id, dates, provisioned device count, and the entitlements. Absent on Simulator/App Store builds.",
                      backingMethod: "GET", backingPathSuffix: "provisioning", readOnlyHint: true, destructiveHint: false),
                .init(name: "bundle_privacy", title: "Declared privacy",
                      description: "Declared privacy usage descriptions, URL schemes, background modes, and App Transport Security summary from Info.plist.",
                      backingMethod: "GET", backingPathSuffix: "privacy", readOnlyHint: true, destructiveHint: false),
                .init(name: "bundle_decode_plist", title: "Decode plist",
                      description: "Decode a binary/XML plist or .strings file (e.g. the bundle's Info.plist) into readable JSON. `path` must be inside an allowed root.",
                      backingMethod: "GET", backingPathSuffix: "plist", readOnlyHint: true, destructiveHint: false),
            ],
            limitations: [
                "The provisioning profile is absent on the Simulator and on App Store builds.",
                "Mach-O cryptid is 0 (decrypted) on Simulator and dev builds; FairPlay encryption (cryptid=1) appears only on App Store binaries.",
                "Compiled assets (Assets.car, nibs) are binary blobs; loose resources and plists are readable.",
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { _, _ in
                .json(BundleInspector.summary())
            },
            HTTPRoute("GET", "macho", annotations: .read) { _, _ in
                .json(MachOInspector.inspect(Bundle.main.executableURL))
            },
            HTTPRoute("GET", "provisioning", annotations: .read) { _, _ in
                .json(ProvisioningInspector.inspect(bundleURL: Bundle.main.bundleURL))
            },
            HTTPRoute("GET", "privacy", annotations: .read) { _, _ in
                .json(BundleInspector.privacy())
            },
            HTTPRoute("GET", "plist", annotations: .read) { req, ctx in
                // Reuse the FilePlugin fence: the path must resolve inside an allowed root.
                guard let url = FilePlugin.resolve(req.query["path"], ctx) else {
                    return .error("forbidden", "Path is outside the allowed sandbox roots.", status: 403)
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                    return .error("not_found", "No such file.", status: 404)
                }
                do {
                    return .json(try BundleInspector.decodePlist(at: url))
                } catch {
                    return .error("not_a_plist", "Not a readable plist: \(error)", status: 422)
                }
            },
        ]
    }
}
