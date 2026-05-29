import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// v1: the discovery endpoint `GET /__sandbox/api/v1/db` is REAL — it scans the sandbox for
/// SQLite databases. Tables/schema/query/exec are registered but `501` until v2 (which wires
/// the system-libsqlite3 backend: read-only `mode=ro` connection, PRAGMA introspection,
/// keyset pagination, and an armed read-write connection).
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
            id: id.rawValue, version: "0.1.0", title: "Databases", panelKey: "db",
            routes: ["GET (discover)", "GET {dbId}/tables", "GET {dbId}/tables/{table}/schema",
                     "POST {dbId}/query", "POST {dbId}/exec"],
            channels: [WSChannel.db.name],
            mcpTools: [
                .init(name: "db_list_databases", title: "List databases",
                      description: "Discover SQLite/Core Data/Realm databases in the sandbox.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_list_tables", title: "List tables",
                      description: "List tables in a database.",
                      backingMethod: "GET", backingPathSuffix: "{dbId}/tables", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_get_schema", title: "Get table schema",
                      description: "Columns and foreign keys for a table.",
                      backingMethod: "GET", backingPathSuffix: "{dbId}/tables/{table}/schema", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_query", title: "Query database",
                      description: "Run a read-only SELECT (paginated).",
                      backingMethod: "POST", backingPathSuffix: "{dbId}/query", readOnlyHint: true, destructiveHint: false),
                .init(name: "db_exec", title: "Execute SQL",
                      description: "Run a mutating statement (requires the database to be armed for writes).",
                      backingMethod: "POST", backingPathSuffix: "{dbId}/exec", readOnlyHint: false, destructiveHint: true),
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { _, context in
                let dbs = DBPlugin.discover(roots: DBPlugin.scanRoots(extra: context.extraRoots()))
                return .json(Page(items: dbs))
            },
            HTTPRoute("GET", "{dbId}/tables", annotations: .read) { _, _ in .notImplemented() },
            HTTPRoute("GET", "{dbId}/tables/{table}/schema", annotations: .read) { _, _ in .notImplemented() },
            HTTPRoute("POST", "{dbId}/query", annotations: .read) { _, _ in .notImplemented() },
            HTTPRoute("POST", "{dbId}/exec", annotations: .destructive) { _, _ in .notImplemented() },
        ]
    }

    func channels() -> [WSChannel] { [.db] }

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
                found.append(DBInfo(
                    id: "db_\(found.count)",
                    engine: "sqlite",
                    name: url.lastPathComponent,
                    path: path,
                    readOnly: true
                ))
            }
        }
        return found
    }
}
