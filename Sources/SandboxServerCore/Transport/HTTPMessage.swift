import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Parsed request line + headers. Header names are lower-cased for case-insensitive lookup.
struct HTTPRequestHead: Sendable {
    let method: String
    /// Raw request target, e.g. `/__sandbox/api/v1/net/requests?limit=50`.
    let target: String
    let version: String
    let headers: [String: String]

    var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]) }

    var query: [String: String] {
        guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = kv[0].removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var contentLength: Int { header("content-length").flatMap(Int.init) ?? 0 }

    var isWebSocketUpgrade: Bool {
        (header("upgrade")?.lowercased().contains("websocket") ?? false) &&
        (header("connection")?.lowercased().contains("upgrade") ?? false)
    }

    /// Single byte range parsed from `Range: bytes=start-end`, if present.
    var byteRange: ClosedRange<Int>? {
        guard let raw = header("range"), raw.hasPrefix("bytes=") else { return nil }
        let spec = raw.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        if let end = Int(parts[1]), end >= start { return start...end }
        return start...Int.max // open-ended; clamped by the producer to the resource length
    }
}

enum HTTPError: Error {
    case headerTooLarge
    case payloadTooLarge
    case truncatedBody
    case malformed
}

/// Reads framed HTTP/1.1 messages off a `ServerConnection`, buffering across reads.
final class HTTPConnectionReader {
    private let connection: any ServerConnection
    private var buffer: [UInt8] = []
    private let maxHeaderBytes = 64 * 1024

    /// Hard cap on a single request body. A hostile/buggy `Content-Length` could otherwise
    /// drive `readBody` to buffer an unbounded amount and OOM the host process.
    static let maxBodyBytes = 64 * 1024 * 1024 // 64 MiB

    init(_ connection: any ServerConnection) { self.connection = connection }

    /// Reads up to (and consuming) the header terminator. Returns `nil` on a clean EOF
    /// before any bytes (idle keep-alive close).
    func readHead() async throws -> HTTPRequestHead? {
        while true {
            if let idx = indexOfDoubleCRLF(buffer) {
                let headBytes = Array(buffer[..<idx])
                buffer.removeFirst(idx + 4)
                return try Self.parse(headBytes)
            }
            guard let chunk = try await connection.receive() else {
                if buffer.isEmpty { return nil } // clean idle close
                throw HTTPError.malformed         // closed mid-header
            }
            buffer.append(contentsOf: chunk)
            if buffer.count > maxHeaderBytes { throw HTTPError.headerTooLarge }
        }
    }

    /// Reads exactly `length` body bytes (buffered leftover first, then the socket).
    /// Throws `payloadTooLarge` if the declared length exceeds the cap, and `truncatedBody`
    /// if the peer closes before the full body arrives (rather than silently truncating).
    func readBody(length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        guard length <= Self.maxBodyBytes else { throw HTTPError.payloadTooLarge }
        while buffer.count < length {
            guard let chunk = try await connection.receive() else { throw HTTPError.truncatedBody }
            buffer.append(contentsOf: chunk)
        }
        let take = min(length, buffer.count)
        let body = Array(buffer[..<take])
        buffer.removeFirst(take)
        return Data(body)
    }

    /// Bytes already read past the header terminator (handed to the WS frame loop on upgrade).
    var leftover: [UInt8] { buffer }

    private func indexOfDoubleCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    private static func parse(_ bytes: [UInt8]) throws -> HTTPRequestHead {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw HTTPError.malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPError.malformed }
        let comps = requestLine.split(separator: " ")
        guard comps.count >= 3 else { throw HTTPError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequestHead(
            method: comps[0].uppercased(),
            target: String(comps[1]),
            version: String(comps[2]),
            headers: headers
        )
    }
}

/// Serializes an `SBResponse` onto a connection. Uses `Content-Length` when the size is
/// known and chunked transfer-encoding when streaming an unknown length.
enum HTTPResponseWriter {
    static func write(_ response: SBResponse, to connection: any ServerConnection, closeAfter: Bool) async throws {
        switch response.body {
        case .empty:
            try await writeHead(response, contentLength: 0, to: connection, closeAfter: closeAfter)
        case .json(let data):
            var r = response
            r.headers["Content-Type"] = "application/json; charset=utf-8"
            try await writeHead(r, contentLength: data.count, to: connection, closeAfter: closeAfter)
            try await connection.send([UInt8](data))
        case .bytes(let data, let contentType):
            var r = response
            r.headers["Content-Type"] = contentType
            try await writeHead(r, contentLength: data.count, to: connection, closeAfter: closeAfter)
            try await connection.send([UInt8](data))
        case .stream(let stream, let contentType, let totalLength):
            var r = response
            r.headers["Content-Type"] = contentType
            if let totalLength {
                try await writeHead(r, contentLength: totalLength, to: connection, closeAfter: closeAfter)
                for try await chunk in stream { try await connection.send(Array(chunk)) }
            } else {
                r.headers["Transfer-Encoding"] = "chunked"
                try await writeHead(r, contentLength: nil, to: connection, closeAfter: closeAfter)
                for try await chunk in stream {
                    let size = String(chunk.count, radix: 16)
                    try await connection.send(Array("\(size)\r\n".utf8) + Array(chunk) + Array("\r\n".utf8))
                }
                try await connection.send(Array("0\r\n\r\n".utf8))
            }
        }
    }

    private static func writeHead(
        _ response: SBResponse, contentLength: Int?, to connection: any ServerConnection, closeAfter: Bool
    ) async throws {
        var lines = ["HTTP/1.1 \(response.status) \(reason(response.status))"]
        var headers = response.headers
        if let contentLength { headers["Content-Length"] = String(contentLength) }
        headers["Connection"] = closeAfter ? "close" : "keep-alive"
        headers["Date"] = httpDate()
        for (k, v) in headers { lines.append("\(k): \(v)") }
        let head = lines.joined(separator: "\r\n") + "\r\n\r\n"
        try await connection.send(Array(head.utf8))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 101: return "Switching Protocols"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Status"
        }
    }

    private static func httpDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date())
    }
}
