import Foundation

/// Writes result lines to standard output and the run's report.txt. Each line goes straight to the file
/// descriptors (no buffering), so nothing is lost when the watchdog ends the process with `_exit`.
/// Safe to use from any thread.
final class E2EOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let report: FileHandle?

    init(reportURL: URL) {
        FileManager.default.createFile(atPath: reportURL.path, contents: nil)
        report = try? FileHandle(forWritingTo: reportURL)
    }

    func line(_ text: String) {
        let data = Data((text + "\n").utf8)
        lock.withLock {
            FileHandle.standardOutput.write(data)
            report?.write(data)
        }
    }
}

/// Ends a stuck run. Each step arms it with its own timeout; if the step has not finished by then, it prints
/// `E2E: TIMEOUT <step>` and exits with code 2. It runs on a background queue, so it still fires when the main
/// thread is blocked (for example inside Chromium's shutdown).
final class E2EWatchdog: @unchecked Sendable {
    static let timeoutExitCode: Int32 = 2
    static let beforeExitTimeout: TimeInterval = 2

    private let lock = NSLock()
    private let output: E2EOutput
    private let beforeExit: @Sendable () -> Void
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    private var step = ""
    private var deadline = DispatchTime.distantFuture

    /// `beforeExit` runs on the watchdog's queue after the TIMEOUT line, just before the process exits.
    init(output: E2EOutput, beforeExit: @escaping @Sendable () -> Void = {}) {
        self.output = output
        self.beforeExit = beforeExit
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [self] in fire() }
        timer.activate()
    }

    /// Starts timing `step`, replacing whatever step was being timed.
    func arm(_ step: String, timeout: TimeInterval) {
        lock.withLock {
            self.step = step
            deadline = .now() + timeout
            timer.schedule(deadline: deadline)
        }
    }

    func disarm() {
        lock.withLock {
            step = ""
            deadline = .distantFuture
            timer.schedule(deadline: deadline)
        }
    }

    private func fire() {
        // Holding the lock to the end keeps a step from being armed in between; checking the deadline ignores a
        // timer event that was already on its way when a newer step re-armed the timer.
        lock.lock()
        guard !step.isEmpty, DispatchTime.now() >= deadline else {
            lock.unlock()
            return
        }
        output.line("E2E: TIMEOUT \(step)")
        // Bounded, so a stuck beforeExit (for example a terminal that stopped reading) cannot keep the run alive.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [beforeExit] in
            beforeExit()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + Self.beforeExitTimeout)
        _exit(Self.timeoutExitCode)
    }
}
