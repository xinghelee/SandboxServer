import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Serves the bundled Preact console from the resource bundle. Not a `SandboxPlugin` — it
/// handles the non-`/__sandbox` paths (`/`, `/assets/*`) directly, without requiring a token
/// so the browser can bootstrap from `?token=`. Path-traversal guarded; correct MIME + caching.
struct StaticConsole: Sendable {
    let webRoot: URL?

    func serve(path: String) -> SBResponse {
        guard let webRoot else {
            return .error("console_unavailable",
                          "Web console assets are not bundled in this build.", status: 404)
        }
        let root = webRoot.standardizedFileURL
        let relative = (path == "/" || path.isEmpty) ? "index.html" : String(path.drop(while: { $0 == "/" }))

        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        // Reject any path that escapes the web root.
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return .error("forbidden", "Path traversal rejected.", status: 403)
        }

        if let response = file(at: candidate, root: root) { return response }
        // SPA fallback: unknown non-asset path → index.html.
        return file(at: root.appendingPathComponent("index.html"), root: root)
            ?? .error("not_found", "Console asset not found.", status: 404)
    }

    private func file(at url: URL, root: URL) -> SBResponse? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: url) else { return nil }
        var response = SBResponse(status: 200, body: .bytes(data, contentType: Self.mime(for: url.pathExtension)))
        response.headers["Cache-Control"] = url.lastPathComponent == "index.html"
            ? "no-cache"
            : "public, max-age=31536000, immutable"
        return response
    }

    private static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
