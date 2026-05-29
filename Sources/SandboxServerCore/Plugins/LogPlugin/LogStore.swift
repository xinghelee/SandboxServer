import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// One captured log line. Shared verbatim by the REST list endpoint and the `logs` WS channel.
struct LogEntry: Encodable, Sendable {
    /// Monotonic, process-wide sequence. The console resumes a live stream from the last `seq` seen.
    let seq: Int
    /// Capture time, unix milliseconds.
    let ts: Int
    /// `debug | info | warn | error`.
    let level: String
    let message: String
    /// Where the line came from: `sdk` (SandboxServer's own logger), `stdout` / `stderr`
    /// (console capture), or `app` (`SandboxServer.log(_:)`).
    let source: String
    let category: String?
}

/// Process-wide log sink: a bounded ring buffer every log source feeds and the `LogPlugin`
/// reads + streams. Deliberately a lock-guarded class (not an actor) so the synchronous SDK
/// logger closure and the fd-capture read callback can append without an `await` hop — the
/// store outlives any single `start()`/`stop()` cycle, so early lines are retained until read.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let lock = NSLock()
    private var items: [LogEntry] = []          // oldest first
    private var nextSeq = 1
    private let maxCount: Int
    private var onAppend: (@Sendable (LogEntry) -> Void)?

    init(maxCount: Int = 5000) { self.maxCount = maxCount }

    /// Install (or clear) the live subscriber the plugin wires in `activate`/`deactivate`.
    func setSubscriber(_ handler: (@Sendable (LogEntry) -> Void)?) {
        lock.lock(); onAppend = handler; lock.unlock()
    }

    /// Append one line. Thread-safe; the subscriber fires *outside* the lock so a slow
    /// publisher can never stall a logging call site.
    @discardableResult
    func emit(level: String, message: String, source: String, category: String? = nil) -> LogEntry {
        lock.lock()
        let entry = LogEntry(
            seq: nextSeq, ts: Int(Date().timeIntervalSince1970 * 1000),
            level: level, message: message, source: source, category: category
        )
        nextSeq += 1
        items.append(entry)
        if items.count > maxCount { items.removeFirst(items.count - maxCount) }
        let handler = onAppend
        lock.unlock()
        handler?(entry)
        return entry
    }

    /// Page of entries, optionally filtered by level, substring, and a `seq` lower bound.
    ///
    /// Two shapes by intent:
    ///  - no `sinceSeq` (tail / search): the *newest* `limit` matches, newest-first, no cursor.
    ///  - with `sinceSeq` (incremental resume): the CONTIGUOUS *oldest-first* matches right after
    ///    the cursor, plus a real `nextCursor` so a caller can page forward without gaps.
    func list(level: String?, contains: String?, sinceSeq: Int?, limit: Int) -> Page<LogEntry> {
        lock.lock(); let snapshot = items; lock.unlock()
        let needle = contains?.lowercased()
        let matches = snapshot.filter { e in   // natural (oldest-first) order
            (level.map { e.level == $0 } ?? true) &&
            (sinceSeq.map { e.seq > $0 } ?? true) &&
            (needle.map { e.message.lowercased().contains($0) } ?? true)
        }
        if sinceSeq != nil {
            let page = Array(matches.prefix(limit))
            let next = matches.count > limit ? page.last.map { String($0.seq) } : nil
            return Page(items: page, nextCursor: next)
        }
        return Page(items: Array(matches.reversed().prefix(limit)), nextCursor: nil)
    }

    func clear() -> Int {
        lock.lock(); let n = items.count; items.removeAll(); lock.unlock(); return n
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

/// Cheap heuristic level from a raw line. Anchored to bracketed/prefixed tokens that real log
/// formatters emit, so bare substrings inside URLs/paths/identifiers (e.g. `…/errors?x=1`) don't
/// get miscoloured. Refined attribution (os_log subsystems, real levels) is a later pass.
func guessLogLevel(_ line: String) -> String {
    let l = line.lowercased()
    if line.contains("❌") || line.contains("🛑")
        || l.contains("[error]") || l.contains("error:") || l.contains("fatal error")
        || l.contains("[fault]") || l.contains("exception:") { return "error" }
    if line.contains("⚠️") || l.contains("[warn") || l.contains("warning:") || l.contains("warn:") { return "warn" }
    if l.contains("[debug]") || l.contains("debug:") || l.contains("[verbose]") || l.contains("verbose:") { return "debug" }
    return "info"
}
