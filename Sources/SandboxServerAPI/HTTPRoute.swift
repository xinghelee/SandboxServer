import Foundation

/// Semantic hints about a route. Mirrored into the plugin manifest and, from there,
/// into MCP tool annotations (`readOnlyHint` / `destructiveHint`).
public struct RouteAnnotations: Sendable, Equatable {
    /// Pure read; safe to call repeatedly and to parallelise.
    public var readOnly: Bool
    /// Mutates or deletes host data; the console and MCP surface this prominently.
    public var destructive: Bool
    /// Produces a large/streamed body; honours `Range` requests.
    public var streaming: Bool

    public init(readOnly: Bool = true, destructive: Bool = false, streaming: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.streaming = streaming
    }

    public static let read = RouteAnnotations(readOnly: true)
    public static let write = RouteAnnotations(readOnly: false)
    public static let destructive = RouteAnnotations(readOnly: false, destructive: true)
}

/// One HTTP route a plugin exposes. Mounted by the core under
/// `/__sandbox/api/v1/<pluginID>/<pathSuffix>`. Pure description plus a handler.
///
/// `pathSuffix` may contain `{name}` segments captured into `SBRequest.pathParams`,
/// e.g. `"requests/{id}"` or `"{dbId}/tables/{table}/schema"`.
public struct HTTPRoute: Sendable {
    public let method: String
    public let pathSuffix: String
    public let annotations: RouteAnnotations
    public let handler: @Sendable (SBRequest, any PluginContext) async throws -> SBResponse

    public init(
        _ method: String,
        _ pathSuffix: String,
        annotations: RouteAnnotations = .read,
        handler: @escaping @Sendable (SBRequest, any PluginContext) async throws -> SBResponse
    ) {
        self.method = method.uppercased()
        self.pathSuffix = pathSuffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.annotations = annotations
        self.handler = handler
    }
}
