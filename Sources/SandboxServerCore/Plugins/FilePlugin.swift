import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Browses and edits the host app's sandbox. Every path is resolved and confined to an allowed
/// root (the app container plus any host-registered extra roots) — requests that escape are
/// rejected with 403. Reads stream off disk and honour HTTP Range; writes accept utf8/base64.
struct FilePlugin: SandboxPlugin {
    let id = PluginID.fs

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Files", panelKey: "files",
            routes: ["GET roots", "GET list", "GET stat", "GET file", "PUT file", "POST move", "DELETE file"],
            channels: [],
            mcpTools: [
                .init(name: "fs_roots", title: "List roots",
                      description: "List the sandbox roots available for browsing.",
                      backingMethod: "GET", backingPathSuffix: "roots", readOnlyHint: true, destructiveHint: false),
                .init(name: "fs_list_dir", title: "List directory",
                      description: "List entries under a sandbox directory path.",
                      backingMethod: "GET", backingPathSuffix: "list", readOnlyHint: true, destructiveHint: false),
                .init(name: "fs_stat", title: "Stat path",
                      description: "Metadata for a sandbox file or directory.",
                      backingMethod: "GET", backingPathSuffix: "stat", readOnlyHint: true, destructiveHint: false),
                .init(name: "fs_read_file", title: "Read file",
                      description: "Read a sandbox file's bytes (text or base64).",
                      backingMethod: "GET", backingPathSuffix: "file", readOnlyHint: true, destructiveHint: false),
                .init(name: "fs_write_file", title: "Write file",
                      description: "Create or overwrite a sandbox file.",
                      backingMethod: "PUT", backingPathSuffix: "file", readOnlyHint: false, destructiveHint: true),
                .init(name: "fs_move", title: "Move path",
                      description: "Move or rename a sandbox file or directory.",
                      backingMethod: "POST", backingPathSuffix: "move", readOnlyHint: false, destructiveHint: false),
                .init(name: "fs_delete", title: "Delete path",
                      description: "Delete a sandbox file or directory.",
                      backingMethod: "DELETE", backingPathSuffix: "file", readOnlyHint: false, destructiveHint: true),
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "roots", annotations: .read) { _, ctx in Self.listRoots(ctx) },
            HTTPRoute("GET", "list", annotations: .read) { req, ctx in Self.list(req, ctx) },
            HTTPRoute("GET", "stat", annotations: .read) { req, ctx in Self.stat(req, ctx) },
            HTTPRoute("GET", "file", annotations: RouteAnnotations(readOnly: true, streaming: true)) { req, ctx in
                Self.read(req, ctx)
            },
            HTTPRoute("PUT", "file", annotations: .write) { req, ctx in try await Self.write(req, ctx) },
            HTTPRoute("POST", "move", annotations: .write) { req, ctx in try await Self.move(req, ctx) },
            HTTPRoute("DELETE", "file", annotations: .destructive) { req, ctx in Self.delete(req, ctx) },
        ]
    }

    // MARK: - Roots & path confinement

    static func roots(_ ctx: any PluginContext) -> [URL] {
        ([URL(fileURLWithPath: NSHomeDirectory())] + ctx.extraRoots()).map { $0.standardizedFileURL }
    }

    /// Resolves `path` to a URL confined to an allowed root, or `nil` if it escapes.
    ///
    /// Symlinks are resolved on BOTH the target and the roots before comparison, so a symlink
    /// inside a root cannot redirect reads/writes outside it. For a not-yet-existing leaf (e.g. a
    /// new file via PUT), only the parent directory's symlinks are resolved, then the leaf re-appended.
    static func resolve(_ path: String?, _ ctx: any PluginContext) -> URL? {
        let roots = roots(ctx).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard let path, !path.isEmpty, path != "/" else { return roots.first }

        let raw = URL(fileURLWithPath: path)
        let resolved: URL
        if FileManager.default.fileExists(atPath: raw.path) {
            resolved = raw.resolvingSymlinksInPath().standardizedFileURL
        } else {
            let parent = raw.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            resolved = parent.appendingPathComponent(raw.lastPathComponent).standardizedFileURL
        }
        let p = resolved.path
        for root in roots where p == root.path || p.hasPrefix(root.path + "/") {
            return resolved
        }
        return nil
    }

    /// Whether `url` lies within a root the host marked read-only (e.g. the OS-mounted `.app`
    /// bundle). Symlinks are resolved on both sides, mirroring `resolve`.
    static func isReadOnly(_ url: URL, _ ctx: any PluginContext) -> Bool {
        let readOnly = ctx.readOnlyRoots().map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path
        return readOnly.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    // MARK: - DTOs

    struct FileEntry: Encodable, Sendable {
        let name: String
        let path: String
        let isDir: Bool
        let size: Int
        let mtime: Int      // unix milliseconds
        let mime: String
    }
    struct RootEntry: Encodable, Sendable { let name: String; let path: String }
    struct WriteResult: Encodable, Sendable { let path: String; let size: Int }

    // MARK: - Handlers

    static func listRoots(_ ctx: any PluginContext) -> SBResponse {
        let items = roots(ctx).map { RootEntry(name: $0.lastPathComponent, path: $0.path) }
        return .json(Page(items: items))
    }

    static func list(_ req: SBRequest, _ ctx: any PluginContext) -> SBResponse {
        guard let dir = resolve(req.query["path"], ctx) else { return forbidden() }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return .error("not_found", "No such directory.", status: 404)
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return .error("io_error", "Could not read directory.", status: 500)
        }
        var entries = names.map { entry(for: dir.appendingPathComponent($0)) }
        // Directories first, then case-insensitive name.
        entries.sort { a, b in a.isDir != b.isDir ? a.isDir : a.name.lowercased() < b.name.lowercased() }

        let limit = max(1, min(2000, Int(req.query["limit"] ?? "") ?? 1000))
        let offset = Int(req.query["cursor"] ?? "") ?? 0
        let slice = Array(entries.dropFirst(offset).prefix(limit))
        let next = offset + slice.count < entries.count ? String(offset + slice.count) : nil
        return .json(PageWithPath(path: dir.path, items: slice, nextCursor: next))
    }

    static func stat(_ req: SBRequest, _ ctx: any PluginContext) -> SBResponse {
        guard let url = resolve(req.query["path"], ctx) else { return forbidden() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error("not_found", "No such path.", status: 404)
        }
        return .json(entry(for: url))
    }

    static func read(_ req: SBRequest, _ ctx: any PluginContext) -> SBResponse {
        guard let url = resolve(req.query["path"], ctx) else { return forbidden() }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return .error("not_found", "No such file.", status: 404)
        }
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let mime = mimeType(url.pathExtension)

        var start = 0
        var end = size - 1
        var status = 200
        var headers: [String: String] = ["Accept-Ranges": "bytes"]
        if let range = req.range {
            // A Range on a 0-byte resource is never satisfiable (RFC 7233 §4.4) — don't fall
            // through to a 200 full-body response.
            guard size > 0 else {
                return .error("range_not_satisfiable", "Range not satisfiable for an empty resource.", status: 416)
            }
            switch range {
            case .explicit(let lower, let upper):
                start = max(0, lower)
                end = min(size - 1, upper)
            case .suffix(let n):
                start = max(0, size - n) // last N bytes; clamps to the whole file when N ≥ size
                end = size - 1
            }
            if start > end { return .error("range_not_satisfiable", "Invalid range.", status: 416) }
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }
        let length = size == 0 ? 0 : end - start + 1
        let stream = fileStream(url: url, offset: start, length: length)
        return SBResponse(status: status, headers: headers,
                          body: .stream(stream, contentType: mime, totalLength: length))
    }

    static func write(_ req: SBRequest, _ ctx: any PluginContext) async throws -> SBResponse {
        guard let url = resolve(req.query["path"], ctx) else { return forbidden() }
        if isReadOnly(url, ctx) { return readOnly() }
        struct Payload: Decodable { let content: String; let encoding: String? }
        let data: Data
        if let payload = try? await req.decodeJSON(Payload.self) {
            if payload.encoding == "base64" {
                guard let decoded = Data(base64Encoded: payload.content) else {
                    return .error("bad_request", "Invalid base64 content.", status: 400)
                }
                data = decoded
            } else {
                data = Data(payload.content.utf8)
            }
        } else {
            data = try await req.bodyData() // raw bytes fallback
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return .error("io_error", "Write failed: \(error.localizedDescription)", status: 500)
        }
        return .json(WriteResult(path: url.path, size: data.count))
    }

    static func move(_ req: SBRequest, _ ctx: any PluginContext) async throws -> SBResponse {
        struct Payload: Decodable { let from: String; let to: String; let overwrite: Bool? }
        guard let payload = try? await req.decodeJSON(Payload.self),
              let from = resolve(payload.from, ctx), let to = resolve(payload.to, ctx) else {
            return forbidden()
        }
        // A move mutates both endpoints (writes `to`, removes `from`), so neither may be read-only.
        if isReadOnly(from, ctx) || isReadOnly(to, ctx) { return readOnly() }
        let fm = FileManager.default
        do {
            if payload.overwrite == true, fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.moveItem(at: from, to: to)
        } catch {
            return .error("io_error", "Move failed: \(error.localizedDescription)", status: 500)
        }
        return .json(entry(for: to))
    }

    static func delete(_ req: SBRequest, _ ctx: any PluginContext) -> SBResponse {
        guard let url = resolve(req.query["path"], ctx) else { return forbidden() }
        if isReadOnly(url, ctx) { return readOnly() }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .error("not_found", "No such path.", status: 404)
        }
        if isDir.boolValue, req.query["recursive"] != "true" {
            return .error("not_empty", "Refusing to delete a directory without recursive=true.", status: 400)
        }
        // Never allow deleting a root itself.
        if roots(ctx).contains(where: { $0.path == url.path }) {
            return .error("forbidden", "Refusing to delete a sandbox root.", status: 403)
        }
        do { try fm.removeItem(at: url) } catch {
            return .error("io_error", "Delete failed: \(error.localizedDescription)", status: 500)
        }
        return .json(["deleted": true])
    }

    // MARK: - Helpers

    private static func forbidden() -> SBResponse {
        .error("forbidden", "Path is outside the allowed sandbox roots.", status: 403)
    }

    private static func readOnly() -> SBResponse {
        .error("forbidden", "This root is mounted read-only (e.g. the app bundle); writes are not allowed.", status: 403)
    }

    private static func entry(for url: URL) -> FileEntry {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        return FileEntry(
            name: url.lastPathComponent,
            path: url.path,
            isDir: isDir.boolValue,
            size: isDir.boolValue ? 0 : size,
            mtime: mtime,
            mime: isDir.boolValue ? "inode/directory" : mimeType(url.pathExtension)
        )
    }

    private static func fileStream(url: URL, offset: Int, length: Int) -> AsyncThrowingStream<ArraySlice<UInt8>, Error> {
        AsyncThrowingStream { continuation in
            guard length > 0 else { continuation.finish(); return }
            let task = Task.detached {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    var remaining = length
                    let chunkSize = 64 * 1024
                    while remaining > 0 {
                        if Task.isCancelled { break }
                        let toRead = min(chunkSize, remaining)
                        let data = try handle.read(upToCount: toRead) ?? Data()
                        if data.isEmpty { break }
                        continuation.yield(ArraySlice(data))
                        remaining -= data.count
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "txt", "log", "csv": return "text/plain; charset=utf-8"
        case "json", "geojson": return "application/json; charset=utf-8"
        case "xml", "plist": return "application/xml; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "md", "markdown": return "text/markdown; charset=utf-8"
        case "swift", "c", "h", "m", "cpp", "py", "rb", "go", "rs", "java", "kt", "sh", "yml", "yaml", "toml":
            return "text/plain; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "sqlite", "sqlite3", "db": return "application/vnd.sqlite3"
        default: return "application/octet-stream"
        }
    }
}

/// A list payload that also reports the resolved directory path (so the console can show a breadcrumb).
private struct PageWithPath<Item: Encodable & Sendable>: Encodable, Sendable {
    let path: String
    let items: [Item]
    let nextCursor: String?
}
