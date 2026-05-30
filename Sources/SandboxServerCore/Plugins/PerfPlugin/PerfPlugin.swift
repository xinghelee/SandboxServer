import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE. Streams a live performance HUD — FPS, process CPU %, memory footprint (MB + % of device
/// RAM), worst frame hitch, and thermal state — over the `perf` WebSocket channel, sampled on an
/// interval. `GET /perf` returns a one-shot snapshot for the `perf_snapshot` MCP tool. FPS/hitch
/// need a display link (UIKit); on non-UIKit hosts those fields are null and CPU/memory still report.
final class PerfPlugin: SandboxPlugin, @unchecked Sendable {
    let id = PluginID.perf
    private let monitor = PerfMonitor.shared
    private var publishTask: Task<Void, Never>?

    /// Sampling cadence. 0.5s keeps the charts smooth without flooding the socket.
    private let interval: Double = 0.5

    init() {}

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Performance", panelKey: "perf",
            routes: ["GET (snapshot)"],
            channels: [WSChannel.perf.name],
            mcpTools: [
                .init(name: "perf_snapshot", title: "Performance snapshot",
                      description: "Current FPS, process CPU %, memory footprint (MB and % of device RAM), worst frame hitch, and thermal state.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
            ],
            limitations: [
                "FPS and frame-hitch metrics require UIKit (iOS); on non-UIKit hosts they are null.",
                "CPU % is summed across the process's threads, so it can exceed 100% on multi-core devices.",
                "Memory is phys_footprint (the Jetsam-relevant figure), which differs from Xcode's gauge.",
            ]
        )
    }

    func channels() -> [WSChannel] { [.perf] }

    func activate(context: any PluginContext) async throws {
        await monitor.startDisplayLink()
        let monitor = self.monitor
        let interval = self.interval
        publishTask = Task {
            // Prime the frame window so the first sample's elapsed is the real interval.
            var previous = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                let now = Date()
                let elapsed = now.timeIntervalSince(previous)
                previous = now
                let sample = monitor.sample(elapsed: elapsed)
                await context.publish(channel: .perf, type: "perf.sample", payload: sample)
            }
        }
        context.log("performance monitor active — sampling every \(Int(interval * 1000))ms over the perf channel"
            + (PerfMonitor.displayLinkSupported ? "" : " (FPS/hitch unavailable — no UIKit display link)"))
    }

    func deactivate() async {
        publishTask?.cancel()
        publishTask = nil
        await monitor.stopDisplayLink()
    }

    func routes() -> [HTTPRoute] {
        let monitor = self.monitor
        return [
            HTTPRoute("GET", "", annotations: .read) { _, _ in
                .json(monitor.snapshot())
            },
        ]
    }
}
