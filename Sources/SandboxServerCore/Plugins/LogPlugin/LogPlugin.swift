import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE in v1. Streams the app's console/log output to the browser over the `logs` WS channel
/// and exposes it for tailing/searching over REST + MCP. This is the second plugin (after `net`)
/// to exercise the WebSocket fan-out path, proving live streaming generalises beyond network.
///
/// Three ingestion sources feed the shared `LogStore`:
///  - the SDK's own logger (always),
///  - `SandboxServer.log(_:)` host calls (always, tagged `app`),
///  - raw `stdout`/`stderr` via `ConsoleCapture` (opt-in, `SandboxConfig.captureConsole`).
///
/// Lines are published through a single long-lived consumer draining an `AsyncStream` (not a
/// per-line `Task`), so the strict `seq` order assigned under the store's lock is preserved all
/// the way to the WebSocket — otherwise concurrent tasks could reorder a burst and the client,
/// which dedupes on `seq`, would silently drop the late arrivals.
final class LogPlugin: SandboxPlugin, @unchecked Sendable {
    let id = PluginID.logs
    private let store = LogStore.shared
    private var continuation: AsyncStream<LogEntry>.Continuation?
    private var publishTask: Task<Void, Never>?

    init() {}

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Logs", panelKey: "logs",
            routes: ["GET (tail/search)", "DELETE (clear)"],
            channels: [WSChannel.logs.name],
            mcpTools: [
                .init(name: "logs_tail", title: "Tail logs",
                      description: "Return the most recent captured log lines (newest first). Optional `limit`, `sinceSeq` (contiguous lines after a cursor).",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "logs_search", title: "Search logs",
                      description: "Filter captured logs by `level` (debug|info|warn|error) and/or substring `q`.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "logs_clear", title: "Clear logs",
                      description: "Discard all captured log lines.",
                      backingMethod: "DELETE", backingPathSuffix: "", readOnlyHint: false, destructiveHint: true),
            ]
        )
    }

    func channels() -> [WSChannel] { [.logs] }

    func activate(context: any PluginContext) async throws {
        // One ordered consumer serialises WS publishes (iOS 13+ AsyncStream init — not makeStream,
        // which is iOS 17+). bufferingNewest bounds memory under a burst.
        var captured: AsyncStream<LogEntry>.Continuation?
        let stream = AsyncStream<LogEntry>(LogEntry.self, bufferingPolicy: .bufferingNewest(4096)) {
            captured = $0
        }
        guard let cont = captured else { return }
        continuation = cont
        publishTask = Task {
            for await entry in stream {
                await context.publish(channel: .logs, type: "log.appended", payload: entry)
            }
        }
        // Enqueue each newly-appended line in seq order; yield is thread-safe and a no-op after finish().
        store.setSubscriber { entry in cont.yield(entry) }

        if context.config.captureConsole {
            ConsoleCapture.shared.start { source, line in
                LogStore.shared.emit(level: guessLogLevel(line), message: line, source: source)
            }
            context.log("console capture active — stdout/stderr mirrored to the logs stream")
        } else {
            context.log("logs plugin active — console capture off (enable SandboxConfig.captureConsole, or use SandboxServer.log)")
        }
    }

    func deactivate() async {
        ConsoleCapture.shared.stop()
        store.setSubscriber(nil)
        continuation?.finish()
        continuation = nil
        publishTask?.cancel()
        publishTask = nil
    }

    func routes() -> [HTTPRoute] {
        let store = self.store
        return [
            // GET /logs — newest-first tail, with optional ?level= & ?q= & ?sinceSeq= & ?limit=.
            // With ?sinceSeq=, returns the contiguous oldest-first lines after the cursor + nextCursor.
            HTTPRoute("GET", "", annotations: .read) { req, _ in
                let page = store.list(
                    level: req.query["level"].flatMap { $0.isEmpty ? nil : $0 },
                    contains: req.query["q"] ?? req.query["contains"],
                    sinceSeq: req.query["sinceSeq"].flatMap(Int.init),
                    limit: min(Int(req.query["limit"] ?? "") ?? 500, 5000)
                )
                return .json(page)
            },
            // DELETE /logs — flush the ring buffer.
            HTTPRoute("DELETE", "", annotations: .destructive) { _, _ in
                .json(["cleared": store.clear()])
            },
        ]
    }
}
