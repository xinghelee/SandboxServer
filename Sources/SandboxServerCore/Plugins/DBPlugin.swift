import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Discovers and reads SQLite databases in the sandbox. Discovery scans allowed roots; table
/// listing, schema introspection, and queries open a read-only connection via `SQLiteReader`
/// (writes naturally fail). `dbId` is the database's file path, confined through `FilePlugin.resolve`.
/// `exec` (mutations) is intentionally read-only in v2.
struct DBPlugin: SandboxPlugin {
    let id = PluginID.db

    struct DBInfo: Encodable, Sendable {
        let id: String
        let engine: String
        let name: String
        let path: String
        let readOnly: Bool
    }

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Databases", panelKey: "db",
            routes: ["GET (discover)", "GET {dbId}/tables", "GET {dbId}/tables/{table}/schema",
                     "POST {dbId}/query", "POST {dbId}/exec"],
            channels: [],
            mcpTools: [
                .init(name: "db_list_databases", title: "List databases",
                      description: "Discover SQLite databases in the sandbox.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_list_tables", title: "List tables",
                      description: "List tables/views in a database (with row counts).",
                      backingMethod: "GET", backingPathSuffix: "{dbId}/tables", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_get_schema", title: "Get table schema",
                      description: "Columns and foreign keys for a table.",
                      backingMethod: "GET", backingPathSuffix: "{dbId}/tables/{table}/schema", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_query", title: "Query database",
                      description: "Run a read-only SELECT, or browse a table, paginated.",
                      backingMethod: "POST", backingPathSuffix: "{dbId}/query", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_exec", title: "Execute SQL",
                      description: "Mutating statements (read-only in this version).",
                      backingMethod: "POST", backingPathSuffix: "{dbId}/exec", readOnlyHint: false, destructiveHint: true),
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { _, ctx in
                .json(Page(items: DBPlugin.discover(roots: DBPlugin.scanRoots(extra: ctx.extraRoots()))))
            },
            HTTPRoute("GET", "{dbId}/tables", annotations: .read) { req, ctx in
                guard let path = DBPlugin.dbPath(req, ctx) else { return DBPlugin.notFound() }
                do { return .json(Page(items: try SQLiteReader.tables(at: path))) }
                catch { return .error("db_error", "\(error)", status: 500) }
            },
            HTTPRoute("GET", "{dbId}/tables/{table}/schema", annotations: .read) { req, ctx in
                guard let path = DBPlugin.dbPath(req, ctx), let table = req.pathParams["table"] else {
                    return DBPlugin.notFound()
                }
                do { return .json(try SQLiteReader.schema(at: path, table: table)) }
                catch { return .error("db_error", "\(error)", status: 500) }
            },
            HTTPRoute("POST", "{dbId}/query", annotations: .read) { req, ctx in
                guard let path = DBPlugin.dbPath(req, ctx) else { return DBPlugin.notFound() }
                struct Q: Decodable { let sql: String?; let table: String?; let limit: Int?; let cursor: String? }
                let q = try? await req.decodeJSON(Q.self)
                let limit = max(1, min(1000, q?.limit ?? 100))
                let offset = Int(q?.cursor ?? "") ?? 0
                do {
                    return .json(try SQLiteReader.query(at: path, sql: q?.sql, table: q?.table, limit: limit, offset: offset))
                } catch { return .error("db_error", "\(error)", status: 400) }
            },
            HTTPRoute("POST", "{dbId}/exec", annotations: .destructive) { _, _ in
                .error("db_readonly", "Database writes are read-only in this version.", status: 403)
            },
        ]
    }

    // MARK: - Resolution

    /// The confined, existing database file path for `{dbId}`, or `nil`.
    private static func dbPath(_ req: SBRequest, _ ctx: any PluginContext) -> String? {
        guard let id = req.pathParams["dbId"],
              let url = FilePlugin.resolve(id, ctx),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    private static func notFound() -> SBResponse { .error("not_found", "No such database.", status: 404) }

    // MARK: - Discovery (bounded sandbox scan)

    private static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db"]

    static func scanRoots(extra: [URL]) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let defaults = ["Documents", "Library/Application Support", "Library/Caches", "tmp"]
            .map { home.appendingPathComponent($0) }
        return defaults + extra
    }

    static func discover(roots: [URL], maxResults: Int = 200) -> [DBInfo] {
        let fm = FileManager.default
        var found: [DBInfo] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if found.count >= maxResults { break }
                guard sqliteExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                found.append(DBInfo(id: path, engine: "sqlite", name: url.lastPathComponent, path: path, readOnly: true))
            }
        }
        return found
    }
}
