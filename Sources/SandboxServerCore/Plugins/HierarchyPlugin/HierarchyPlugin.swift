import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE on iOS. Exposes the app's live view-hierarchy tree (`GET /hierarchy`) so the browser can
/// render a 3D exploded layer inspector and the `ui_hierarchy` MCP tool can hand the structure to
/// AI. Capture is bounded (`maxDepth` / `maxNodes`). Reports `supported = false` on non-UIKit hosts.
final class HierarchyPlugin: SandboxPlugin, @unchecked Sendable {
    let id = PluginID.hierarchy

    init() {}

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Layers", panelKey: "hierarchy",
            routes: ["GET (view tree)"],
            mcpTools: [
                .init(name: "ui_hierarchy", title: "View hierarchy",
                      description: "The live view-hierarchy tree of the app's key window — class, frame (window coords), depth, alpha, hidden, and label per node. Optional maxDepth / maxNodes.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { req, _ in
                let dto = await ViewHierarchy.capture(
                    maxDepth: min(max(Int(req.query["maxDepth"] ?? "") ?? 40, 1), 100),
                    maxNodes: min(max(Int(req.query["maxNodes"] ?? "") ?? 1500, 1), 4000),
                    thumbs: req.query["thumbs"] == "1" || req.query["thumbs"] == "true",
                    maxThumbs: min(max(Int(req.query["maxThumbs"] ?? "") ?? 220, 0), 500)
                )
                return .json(dto)
            },
        ]
    }
}
