import Foundation
import ObjectiveC

/// Per-task connection id, attached lazily on first interception.
nonisolated(unsafe) private var wsConnIdKey: UInt8 = 0

/// Captures `URLSessionWebSocketTask` traffic. `URLProtocol` cannot see WebSocket frames (they're
/// exchanged outside the URL loading request/response model), so we swizzle the task's own
/// frame-exchange selectors. Only WS-specific selectors are swizzled — never the inherited
/// `resume`, which would intercept every URLSession task.
///
/// Blind spots (documented like the HTTP capture's): raw-socket WS libraries (Starscream,
/// SRWebSocket) and ping/pong/close control frames (the high-level API doesn't surface them).
/// The SDK's own console WebSocket uses Network.framework, not URLSession, so it's never captured.
enum WebSocketSwizzler {
    nonisolated(unsafe) static var store: WSStore?
    nonisolated(unsafe) static var isEnabled = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    static func installIfNeeded() {
        lock.withLock {
            guard !installed else { return }
            installed = true
            // URLSessionWebSocketTask is a class cluster; discover the concrete subclass from a
            // probe (never resumed, so it opens no connection) and swizzle THAT class.
            guard let url = URL(string: "wss://127.0.0.1/"),
                  let cls: AnyClass = object_getClass(URLSession.shared.webSocketTask(with: url))
            else { return }
            swizzleSend(cls)
            swizzleReceive(cls)
            swizzleCancel(cls)
        }
    }

    // MARK: - Swizzles

    private static func swizzleSend(_ cls: AnyClass) {
        let sel = NSSelectorFromString("sendMessage:completionHandler:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, ((Error?) -> Void)?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, ((Error?) -> Void)?) -> Void = { task, message, handler in
            if isEnabled, let store {
                let id = connId(for: task)
                let m = describe(message)
                Task { await store.record(connId: id, dir: .sent, opcode: m.opcode, preview: m.preview, size: m.size) }
            }
            original(task, sel, message, handler)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleReceive(_ cls: AnyClass) {
        let sel = NSSelectorFromString("receiveMessageWithCompletionHandler:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, ((AnyObject?, Error?) -> Void)?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let block: @convention(block) (AnyObject, ((AnyObject?, Error?) -> Void)?) -> Void = { task, handler in
            if isEnabled, let store {
                let id = connId(for: task)
                let wrapped: (AnyObject?, Error?) -> Void = { message, error in
                    if let message {
                        let m = describe(message)
                        Task { await store.record(connId: id, dir: .received, opcode: m.opcode, preview: m.preview, size: m.size) }
                    } else if let error {
                        Task { await store.close(connId: id, state: .failed, reason: nil, error: "\(error)") }
                    }
                    handler?(message, error)
                }
                original(task, sel, wrapped)
            } else {
                original(task, sel, handler)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleCancel(_ cls: AnyClass) {
        let sel = NSSelectorFromString("cancelWithCloseCode:reason:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Int, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let block: @convention(block) (AnyObject, Int, AnyObject?) -> Void = { task, code, reason in
            if isEnabled, let store {
                let id = connId(for: task)
                let text = (reason as? Data).flatMap { String(data: $0, encoding: .utf8) }
                Task { await store.close(connId: id, state: .closed, reason: text ?? "code \(code)", error: nil) }
            }
            original(task, sel, code, reason)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Helpers

    /// Get-or-assign the connection id for a task; on first sight, record the connection as open.
    private static func connId(for task: AnyObject) -> String {
        if let existing = objc_getAssociatedObject(task, &wsConnIdKey) as? String { return existing }
        let id = UUID().uuidString
        objc_setAssociatedObject(task, &wsConnIdKey, id, .OBJC_ASSOCIATION_RETAIN)
        let url = (task as? URLSessionTask)?.originalRequest?.url
        if let store {
            Task { await store.open(id: id, url: url?.absoluteString ?? "(unknown)", host: url?.host ?? "") }
        }
        return id
    }

    /// Reads a WebSocket message object via KVC (it's an NSURLSessionWebSocketMessage).
    private static func describe(_ message: AnyObject?) -> (opcode: String, preview: String?, size: Int) {
        guard let message else { return ("text", nil, 0) }
        if let s = message.value(forKey: "string") as? String {
            return ("text", String(s.prefix(64 * 1024)), s.utf8.count)
        }
        if let d = message.value(forKey: "data") as? Data {
            return ("binary", "<binary \(d.count) bytes>", d.count)
        }
        return ("text", nil, 0)
    }
}
