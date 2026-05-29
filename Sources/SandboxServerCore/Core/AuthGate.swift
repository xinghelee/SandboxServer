import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Per-session bearer-token gate, enforced by the middleware chain before any plugin runs.
///
/// A fresh token is minted on construction (once per `start()`), compared in constant time,
/// and never persisted. After too many failures the gate locks out briefly.
final class AuthGate: @unchecked Sendable {
    let mode: AuthMode
    let token: String?

    private let lock = NSLock()
    private var failedAttempts = 0
    private var lockedUntil: Date?
    private let maxFailures = 20
    private let lockoutSeconds: TimeInterval = 30

    init(mode: AuthMode) {
        self.mode = mode
        self.token = (mode == .token) ? Self.generateToken() : nil
    }

    /// Authorises a request by `Authorization: Bearer <t>` or a bootstrap `?token=<t>`.
    func isAuthorized(token presented: String?) -> Bool {
        guard mode == .token else { return true }
        guard let expected = token else { return true }

        if let until = lock.withLock({ lockedUntil }), until > Date() { return false }

        guard let presented, Self.constantTimeEquals(presented, expected) else {
            lock.withLock {
                failedAttempts += 1
                if failedAttempts >= maxFailures {
                    lockedUntil = Date().addingTimeInterval(lockoutSeconds)
                    failedAttempts = 0
                }
            }
            return false
        }
        lock.withLock { failedAttempts = 0; lockedUntil = nil }
        return true
    }

    static func extractToken(header authorization: String?, query: [String: String]) -> String? {
        if let authorization, authorization.lowercased().hasPrefix("bearer ") {
            return String(authorization.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return query["token"]
    }

    private static func generateToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in rng.next() as UInt8 }
        return base32(bytes)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    private static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer = 0, bitsLeft = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1F
                bitsLeft -= 5
                output.append(alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1F
            output.append(alphabet[index])
        }
        return output
    }
}
