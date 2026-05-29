import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// v1 STUB. Registered and capability-reporting (so the console renders a Files nav item and
/// the MCP bridge can register `fs_*` tools), but every route returns `501 not_implemented`.
/// v2 fills the sandbox walk + stat/read/write/upload/download/move with Range streaming.
struct FilePlugin: SandboxPlugin {
    let id = PluginID.fs

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "0.1.0", title: "Files", panelKey: "files",
            routes: ["GET list", "GET stat", "GET file", "PUT file", "POST upload", "POST move", "DELETE file"],
            channels: [WSChannel.fs.name],
            mcpTools: [
                .init(name: "fs_list_dir", title: "List directory",
                      description: "List entries under a sandbox path.",
                      backingMethod: "GET", backingPathSuffix: "list", readOnlyHint: true, destructiveHint: false),
                .init(name: "fs_stat", title: "Stat path",
                      description: "Metadata for a sandbox file or directory.",
                      backingMethod: "GET", backingPathSuffix: "stat", readOnlyHint: true, destructiveHint: false),
                .init(name: "fs_read_file", title: "Read file",
                      description: "Read a sandbox file (large files surface as a resource).",
                      backingMethod: "GET", backingPathSuffix: "file", readOnlyHint: true, destructiveHint: false),
                .init(name: "fs_write_file", title: "Write file",
                      description: "Create or overwrite a sandbox file.",
                      backingMethod: "PUT", backingPathSuffix: "file", readOnlyHint: false, destructiveHint: true),
                .init(name: "fs_move", title: "Move path",
                      description: "Move or rename a sandbox file.",
                      backingMethod: "POST", backingPathSuffix: "move", readOnlyHint: false, destructiveHint: false),
                .init(name: "fs_delete", title: "Delete path",
                      description: "Delete a sandbox file or directory.",
                      backingMethod: "DELETE", backingPathSuffix: "file", readOnlyHint: false, destructiveHint: true),
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "list", annotations: .read) { _, _ in .notImplemented() },
            HTTPRoute("GET", "stat", annotations: .read) { _, _ in .notImplemented() },
            HTTPRoute("GET", "file", annotations: RouteAnnotations(readOnly: true, streaming: true)) { _, _ in .notImplemented() },
            HTTPRoute("PUT", "file", annotations: .write) { _, _ in .notImplemented() },
            HTTPRoute("POST", "upload", annotations: .write) { _, _ in .notImplemented() },
            HTTPRoute("POST", "move", annotations: .write) { _, _ in .notImplemented() },
            HTTPRoute("DELETE", "file", annotations: .destructive) { _, _ in .notImplemented() },
        ]
    }

    func channels() -> [WSChannel] { [.fs] }
}
