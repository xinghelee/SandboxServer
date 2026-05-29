import Foundation

/// The value-type request the router hands to a plugin handler.
///
/// The body is exposed as a stream so large uploads never have to be buffered whole;
/// `bodyData()` is a convenience for the common small-JSON case.
public struct SBRequest: Sendable {
    public let method: String
    /// Path *relative to the plugin's mount prefix* (e.g. `"requests/42"` for `/v1/net/requests/42`),
    /// already URL-decoded.
    public let path: String
    /// Named path parameters captured by the route pattern (e.g. `["id": "42"]`).
    public let pathParams: [String: String]
    public let query: [String: String]
    /// Header names are lower-cased for case-insensitive lookup.
    public let headers: [String: String]
    /// Parsed `Range:` header (single range only), if present.
    public let range: ClosedRange<Int>?

    private let bodyProvider: @Sendable () -> AsyncThrowingStream<ArraySlice<UInt8>, Error>

    public init(
        method: String,
        path: String,
        pathParams: [String: String] = [:],
        query: [String: String] = [:],
        headers: [String: String] = [:],
        range: ClosedRange<Int>? = nil,
        body: @escaping @Sendable () -> AsyncThrowingStream<ArraySlice<UInt8>, Error> = { .init { $0.finish() } }
    ) {
        self.method = method
        self.path = path
        self.pathParams = pathParams
        self.query = query
        self.headers = headers
        self.range = range
        self.bodyProvider = body
    }

    /// A fresh stream of the request body. Consume at most once.
    public var bodyStream: AsyncThrowingStream<ArraySlice<UInt8>, Error> { bodyProvider() }

    /// Accumulates the full body into `Data`. Use only for small payloads (JSON commands).
    public func bodyData() async throws -> Data {
        var bytes = [UInt8]()
        for try await chunk in bodyStream { bytes.append(contentsOf: chunk) }
        return Data(bytes)
    }

    /// Decodes the body as JSON into `T`.
    public func decodeJSON<T: Decodable>(_ type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await bodyData())
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// A plugin's response. Supports inline JSON, in-memory bytes, or off-disk streaming (with 206 ranges).
public struct SBResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public enum Body: Sendable {
        case empty
        /// Already-encoded JSON (the `{data,meta}` / `{error}` envelope).
        case json(Data)
        case bytes(Data, contentType: String)
        /// Streamed bytes; `totalLength` enables `Content-Length` / range math when known.
        case stream(AsyncThrowingStream<ArraySlice<UInt8>, Error>, contentType: String, totalLength: Int?)
    }

    public init(status: Int = 200, headers: [String: String] = [:], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

// MARK: - Envelope builders

extension SBResponse {
    private struct Meta: Encodable { let apiVersion = "1"; let ts = Int(Date().timeIntervalSince1970) }
    private struct DataEnvelope<T: Encodable>: Encodable { let data: T; let meta = Meta() }
    private struct ErrorBody: Encodable { let code: String; let message: String; let details: JSONValue? }
    private struct ErrorEnvelope: Encodable { let error: ErrorBody }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// Wraps `value` in the success envelope `{ "data": …, "meta": … }`.
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> SBResponse {
        do {
            let data = try encoder.encode(DataEnvelope(data: value))
            return SBResponse(status: status, body: .json(data))
        } catch {
            return .error("encoding_failed", "Failed to encode response: \(error)", status: 500)
        }
    }

    /// The error envelope `{ "error": { code, message, details } }`.
    public static func error(_ code: String, _ message: String, status: Int, details: JSONValue? = nil) -> SBResponse {
        let body = ErrorEnvelope(error: ErrorBody(code: code, message: message, details: details))
        let data = (try? encoder.encode(body)) ?? Data(#"{"error":{"code":"encoding_failed","message":""}}"#.utf8)
        return SBResponse(status: status, body: .json(data))
    }

    /// 501 for a registered-but-unimplemented route (the v1 file/db stubs).
    public static func notImplemented(_ feature: String = "This endpoint is not implemented in this version") -> SBResponse {
        .error("not_implemented", feature, status: 501)
    }
}

/// A cursor-paginated list payload — the standard list shape across every plugin.
public struct Page<Item: Encodable & Sendable>: Encodable, Sendable {
    public let items: [Item]
    public let nextCursor: String?
    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}
