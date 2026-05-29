import Foundation

/// Optionally tees the process's `stdout`/`stderr` into a sink by redirecting fd 1/2 through
/// pipes — capturing `print`, `NSLog`, and anything written to those descriptors — while still
/// forwarding the raw bytes to the original console so Xcode keeps showing them.
///
/// DEBUG-only and strictly opt-in (`SandboxConfig.captureConsole`). The original descriptors are
/// `dup`-saved on `start()` and restored on `stop()`, so capture is fully reversible. A process
/// singleton because there is exactly one stdout/stderr to own.
final class ConsoleCapture: @unchecked Sendable {
    static let shared = ConsoleCapture()

    private let lock = NSLock()
    private var taps: [Tap] = []
    private var running = false

    /// `true` while fd capture is mirroring the console — the SDK logger checks this so it can
    /// skip its own direct emit (capture will pick the line up from stdout) and avoid duplicates.
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Begin capturing. `sink` receives `(source, line)` for each complete line, where `source`
    /// is `"stdout"` or `"stderr"`. Idempotent: a second call while running is ignored.
    func start(sink: @escaping @Sendable (_ source: String, _ line: String) -> Void) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        let targets: [(Int32, String)] = [(STDOUT_FILENO, "stdout"), (STDERR_FILENO, "stderr")]
        taps = targets.compactMap { Tap(fd: $0.0, source: $0.1, sink: sink) }
        lock.unlock()
        // Unbuffered stdout so `print` lines surface immediately rather than on buffer flush.
        setvbuf(stdout, nil, _IONBF, 0)
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let toTearDown = taps
        taps = []
        lock.unlock()
        for tap in toTearDown { tap.teardown() }
    }

    /// One redirected descriptor: its pipe, the saved original, and a serial read loop.
    private final class Tap {
        private let fd: Int32
        private let saved: Int32
        private let pipe = Pipe()
        private let source: String
        private let sink: @Sendable (String, String) -> Void
        private let queue: DispatchQueue
        private let readSource: DispatchSourceRead
        private var partial = Data()             // only touched on `queue`
        private let maxLine = 64 * 1024

        init?(fd: Int32, source: String, sink: @escaping @Sendable (String, String) -> Void) {
            let saved = dup(fd)
            guard saved >= 0 else { return nil }
            self.fd = fd
            self.saved = saved
            self.source = source
            self.sink = sink
            self.queue = DispatchQueue(label: "sandbox.console.\(source)")
            let readFD = pipe.fileHandleForReading.fileDescriptor
            self.readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)

            // Point fd 1/2 at our pipe's write end; subsequent writes flow to us.
            dup2(pipe.fileHandleForWriting.fileDescriptor, fd)

            readSource.setEventHandler { [weak self] in self?.drain(readFD) }
            readSource.resume()
        }

        private func drain(_ readFD: Int32) {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(readFD, &buf, buf.count)
            guard n > 0 else { return }
            // Tee back to the real console first, so capture never swallows output.
            buf.withUnsafeBytes { raw in _ = write(saved, raw.baseAddress, n) }
            partial.append(contentsOf: buf[0..<n])
            flushLines()
        }

        private func flushLines() {
            let newline: UInt8 = 0x0A
            while let idx = partial.firstIndex(of: newline) {
                let lineData = partial[partial.startIndex..<idx]
                emit(lineData)
                partial.removeSubrange(partial.startIndex...idx)
            }
            // Guard against an unbounded line with no newline (e.g. a progress spinner).
            if partial.count > maxLine {
                emit(partial[partial.startIndex..<partial.endIndex])
                partial.removeAll(keepingCapacity: true)
            }
        }

        private func emit(_ data: Data) {
            // Drop a trailing CR and skip blank lines.
            var slice = data
            if slice.last == 0x0D { slice = slice.dropLast() }
            guard !slice.isEmpty else { return }
            let line = String(decoding: slice, as: UTF8.self)
            sink(source, line)
        }

        func teardown() {
            readSource.cancel()
            // Restore the original descriptor, then release ours.
            dup2(saved, fd)
            close(saved)
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
    }
}
