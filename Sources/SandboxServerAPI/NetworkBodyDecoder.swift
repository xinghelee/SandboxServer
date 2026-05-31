import Foundation

/// A captured request/response body handed to a host-provided ``SandboxConfig/networkBodyDecoder``.
///
/// The decoder exists for ONE purpose: turn bytes the host app encrypts/encodes at the application
/// layer (an AES envelope, a protobuf, a signed payload) into something readable in the console and
/// MCP. It runs **in-process in the host app**, so the keys never leave the device or enter the
/// debug surface — only the string the decoder returns is shown.
///
/// It is strictly display-only. The decoder is invoked on the capture path, in a detached task,
/// **after** the real bytes have already been delivered to the app's `URLSession` caller and only
/// ever feeds the human-readable preview. It cannot alter, delay, or observe a mutation of the live
/// request/response, and `replay` re-issues the original raw bytes — never the decoded text. `body`
/// is a value-type copy, so a decoder physically cannot mutate captured or in-flight state.
public struct NetworkBody: Sendable {
    public enum Direction: Sendable {
        /// `body` is the outgoing request payload.
        case request
        /// `body` is the incoming response payload.
        case response
    }

    /// Whether `body` is the request or the response payload.
    public let direction: Direction
    /// The transaction's absolute URL string.
    public let url: String
    /// The HTTP method of the transaction.
    public let method: String
    /// The captured headers for this side of the exchange (request headers for `.request`,
    /// response headers for `.response`) — unredacted, so the decoder can branch on them.
    public let headers: [String: String]
    /// The transaction's `Content-Type`, if known.
    public let contentType: String?
    /// The raw captured bytes (a copy; mutating it has no effect on anything).
    public let body: Data

    public init(
        direction: Direction,
        url: String,
        method: String,
        headers: [String: String],
        contentType: String?,
        body: Data
    ) {
        self.direction = direction
        self.url = url
        self.method = method
        self.headers = headers
        self.contentType = contentType
        self.body = body
    }
}

/// A host-provided hook that turns a captured body into readable text for the console / MCP.
///
/// Return the decoded string, or `nil` to fall back to the built-in preview (UTF-8 text, else
/// `<binary N bytes>`). It runs synchronously on the capture actor off the request's critical path,
/// so it can never affect the host app's real traffic — but keep it fast and side-effect-free so a
/// slow decoder doesn't back up the live capture stream. Set it via ``SandboxConfig/networkBodyDecoder``.
public typealias NetworkBodyDecoder = @Sendable (NetworkBody) -> String?
