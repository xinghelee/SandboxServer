import Foundation

/// Optionally tees the process's `stdout`/`stderr` into a sink by redirecting fd 1/2 through
/// pipes — capturing `print`, `NSLog`, and anything written to those descriptors — while still
/// forwarding the raw bytes to the original console so Xcode keeps showing them.
///
/// DEBUG-only and strictly opt-in (`SandboxConfig.captureConsole`). The original descriptors are
/// `dup`-saved on `start()` and restored on `stop()`. fd ownership follows the libdispatch
/// contract: a descriptor tracked by a `DispatchSource` is closed/restored ONLY from the source's
/// cancel handler (which runs after the last read event completes), never racing an in-flight read.
/// A process singleton because there is exactly one stdout/stderr to own.
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
        let taps = [(STDOUT_FILENO, "stdout"), (STDERR_FILENO, "stderr")].compactMap {
            Tap(fd: $0.0, source: $0.1, sink: sink)
        }
        // Only declare ourselves active if at least one descriptor was actually redirected, so
        // `isActive` never lies (the SDK logger relies on it to decide whether to self-emit).
        running = !taps.isEmpty
        self.taps = taps
        lock.unlock()
        // Unbuffered stdout so `print` lines surface immediately rather than on buffer flush.
        if running { setvbuf(stdout, nil, _IONBF, 0) }
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let toTearDown = taps
        taps = []
        lock.unlock()
        for tap in toTearDown { tap.teardown() }
        // Restore a sane buffering mode (the original mode can't be queried portably).
        setvbuf(stdout, nil, isatty(STDOUT_FILENO) != 0 ? _IOLBF : _IOFBF, Int(BUFSIZ))
    }

    /// One redirected descriptor: its pipe, the saved original, and a serial read loop.
    private final class Tap {
        private let fd: Int32
        private let saved: Int32              // dup of the ORIGINAL console fd; tee-back target
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
            // Point fd 1/2 at our pipe's write end; subsequent writes flow to us.
            guard dup2(pipe.fileHandleForWriting.fileDescriptor, fd) >= 0 else {
                close(saved)
                return nil
            }
            self.fd = fd
            self.saved = saved
            self.source = source
            self.sink = sink
            self.queue = DispatchQueue(label: "sandbox.console.\(source)")
            let readFD = pipe.fileHandleForReading.fileDescriptor
            self.readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)

            readSource.setEventHandler { [weak self] in self?.drain(readFD) }
            // The cancel handler is the ONLY place fds are restored/closed. libdispatch guarantees
            // it runs on `queue` after the final event handler, so it never races drain().
            readSource.setCancelHandler { [pipe] in
                dup2(saved, fd)            // restore the real console fd
                close(saved)
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            readSource.resume()
        }

        private func drain(_ readFD: Int32) {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(readFD, &buf, buf.count)
            guard n > 0 else { return }
            // Tee back to the ORIGINAL console (saved), NOT fd — fd now points at our pipe, so
            // writing there would feed our own reader and loop forever.
            buf.withUnsafeBytes { raw in Self.writeAll(saved, raw.baseAddress!, n) }
            partial.append(contentsOf: buf[0..<n])
            flushLines()
        }

        private func flushLines() {
            let newline: UInt8 = 0x0A
            while let idx = partial.firstIndex(of: newline) {
                emit(partial[partial.startIndex..<idx])
                partial.removeSubrange(partial.startIndex...idx)
            }
            // Guard against an unbounded line with no newline (e.g. a progress spinner). Back the
            // cut off any trailing incomplete UTF-8 sequence so we never split a codepoint.
            if partial.count > maxLine {
                var cut = partial.endIndex
                var backed = 0
                while backed < 3, cut > partial.startIndex,
                      partial[partial.index(before: cut)] & 0xC0 == 0x80 {
                    cut = partial.index(before: cut); backed += 1
                }
                if cut > partial.startIndex, partial[partial.index(before: cut)] & 0x80 != 0 {
                    cut = partial.index(before: cut) // also drop the lead byte of the trailing sequence
                }
                emit(partial[partial.startIndex..<cut])
                partial.removeSubrange(partial.startIndex..<cut)
            }
        }

        private func emit(_ data: Data) {
            // Drop a trailing CR and skip blank lines.
            var slice = data
            if slice.last == 0x0D { slice = slice.dropLast() }
            guard !slice.isEmpty else { return }
            sink(source, String(decoding: slice, as: UTF8.self))
        }

        func teardown() {
            // Only request cancellation; the cancel handler owns the fd restore/close so it can
            // never run concurrently with (or after a close beneath) an in-flight drain().
            readSource.cancel()
        }

        /// Write all `count` bytes, advancing on short writes and retrying on EINTR, so a signal
        /// or partial pipe write never silently truncates the teed-back console output.
        private static func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) {
            var offset = 0
            while offset < count {
                let n = write(fd, ptr + offset, count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }
}
