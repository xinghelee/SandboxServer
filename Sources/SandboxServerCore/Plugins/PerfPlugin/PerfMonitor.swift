import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// One performance sample: a snapshot of frame rate, CPU, memory footprint, and thermal state.
/// `fps`/`hitchMs` require a display link (UIKit) and are `nil` on non-UIKit hosts. `cpu` is the
/// sum across the process's threads, so it can exceed 100% on multi-core devices.
struct PerfSample: Encodable, Sendable {
    let ts: Int
    let supported: Bool
    let fps: Double?
    let hitchMs: Double?
    let cpu: Double
    let memMB: Double
    let memLimitMB: Double
    let memPct: Double?
    let thermal: String
}

/// Samples process-level performance counters and hands them to a publisher on an interval.
///
/// - **FPS / hitches** come from a `CADisplayLink` on the main run loop: every vsync increments a
///   frame counter and tracks the worst frame interval; `sample(elapsed:)` drains those into a rate
///   and a worst-frame-duration. UIKit-only — compiled out on non-UIKit hosts.
/// - **CPU** is summed from `thread_info(THREAD_BASIC_INFO)` over every non-idle thread.
/// - **Memory** is `task_vm_info.phys_footprint` — the real Jetsam-relevant number, not `resident_size`.
/// - **Thermal** is `ProcessInfo.thermalState`.
///
/// All mach calls are read-only introspection of the current task; nothing here is private API.
final class PerfMonitor: @unchecked Sendable {
    static let shared = PerfMonitor()

    /// FPS/hitch tracking is only available where a CADisplayLink exists (UIKit / iOS).
    static var displayLinkSupported: Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    private let lock = NSLock()
    private var frameCount = 0
    private var worstFrameMs: Double = 0
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var lastSample: PerfSample?

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    #endif

    // MARK: - Display link lifecycle (main-actor: CADisplayLink must attach to the main run loop)

    @MainActor
    func startDisplayLink() {
        #if canImport(UIKit)
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] timestamp in self?.recordFrame(timestamp) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.displayLink = link
        #endif
    }

    @MainActor
    func stopDisplayLink() {
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        #endif
        lock.lock()
        frameCount = 0
        worstFrameMs = 0
        lastFrameTimestamp = 0
        lock.unlock()
    }

    private func recordFrame(_ timestamp: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if lastFrameTimestamp != 0 {
            let dtMs = (timestamp - lastFrameTimestamp) * 1000.0
            if dtMs > worstFrameMs { worstFrameMs = dtMs }
        }
        lastFrameTimestamp = timestamp
        frameCount += 1
    }

    /// FPS + worst frame duration over `elapsed` seconds, then reset the window.
    private func drainFrameStats(elapsed: Double) -> (fps: Double?, hitchMs: Double?) {
        lock.lock(); defer { lock.unlock() }
        guard PerfMonitor.displayLinkSupported, elapsed > 0 else {
            frameCount = 0; worstFrameMs = 0
            return (nil, nil)
        }
        let fps = Double(frameCount) / elapsed
        let hitch = worstFrameMs
        frameCount = 0
        worstFrameMs = 0
        return (fps, hitch > 0 ? hitch : nil)
    }

    // MARK: - Sampling

    /// Build a sample covering the last `elapsed` seconds and cache it as the latest value.
    func sample(elapsed: Double) -> PerfSample {
        let (fps, hitch) = drainFrameStats(elapsed: elapsed)
        let footprint = PerfMonitor.memoryFootprint()
        let physical = ProcessInfo.processInfo.physicalMemory
        let memMB = footprint.map { Double($0) / 1_048_576.0 }
        let limitMB = Double(physical) / 1_048_576.0
        let sample = PerfSample(
            ts: Int(Date().timeIntervalSince1970 * 1000),
            supported: PerfMonitor.displayLinkSupported,
            fps: fps.map { round1($0) },
            hitchMs: hitch.map { round1($0) },
            cpu: round1(PerfMonitor.cpuUsage()),
            memMB: memMB.map { round1($0) } ?? 0,
            memLimitMB: limitMB.rounded(),
            memPct: (memMB != nil && limitMB > 0) ? round1(memMB! / limitMB * 100.0) : nil,
            thermal: PerfMonitor.thermalString()
        )
        lock.lock(); lastSample = sample; lock.unlock()
        return sample
    }

    /// A one-shot reading for the `GET /perf` route. Reuses the latest streamed FPS (a standalone
    /// request has no interval over which to compute one) but reads CPU/memory/thermal fresh.
    func snapshot() -> PerfSample {
        lock.lock(); let cached = lastSample; lock.unlock()
        let footprint = PerfMonitor.memoryFootprint()
        let physical = ProcessInfo.processInfo.physicalMemory
        let memMB = footprint.map { Double($0) / 1_048_576.0 }
        let limitMB = Double(physical) / 1_048_576.0
        return PerfSample(
            ts: Int(Date().timeIntervalSince1970 * 1000),
            supported: PerfMonitor.displayLinkSupported,
            fps: cached?.fps,
            hitchMs: cached?.hitchMs,
            cpu: round1(PerfMonitor.cpuUsage()),
            memMB: memMB.map { round1($0) } ?? 0,
            memLimitMB: limitMB.rounded(),
            memPct: (memMB != nil && limitMB > 0) ? round1(memMB! / limitMB * 100.0) : nil,
            thermal: PerfMonitor.thermalString()
        )
    }

    private func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    // MARK: - Mach counters

    /// Sum of per-thread CPU usage as a percentage. Idle threads are excluded.
    private static func cpuUsage() -> Double {
        var threadsArray: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadsArray, &threadCount) == KERN_SUCCESS,
              let threads = threadsArray else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride))
        }
        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            if info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    /// The process's physical memory footprint (the value iOS compares against the Jetsam limit).
    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    private static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

#if canImport(UIKit)
/// CADisplayLink needs an ObjC target/selector; this forwards each tick to a closure.
private final class DisplayLinkProxy: NSObject {
    private let onTick: (CFTimeInterval) -> Void
    init(_ onTick: @escaping (CFTimeInterval) -> Void) { self.onTick = onTick }
    @objc func tick(_ link: CADisplayLink) { onTick(link.timestamp) }
}
#endif
