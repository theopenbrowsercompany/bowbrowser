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

/// Ends a stuck run. While tests run, the runner re-arms it from the main dispatch queue a few times a second, so it
/// fires only when the harness stops being served there, a blocked main thread or one stuck in a nested run loop
/// (a slow step fails on its own and the run goes on); around engine
/// start and quit it is armed with those phases' limits. When it fires it prints `E2E: TIMEOUT <step>` and a
/// `NOT RUN <test>` line for each test that never ran, writes a stack sample of the app to `hang.txt` in the run
/// folder, and exits with code 2. It runs on a background queue, so it still fires when the main thread is blocked
/// (for example inside Chromium's shutdown).
final class E2EWatchdog: @unchecked Sendable {
    static let timeoutExitCode: Int32 = 2
    static let beforeExitTimeout: TimeInterval = 2
    /// The stack sample's length in seconds, and how long the watchdog waits for `sample` to finish.
    static let sampleSeconds = 1
    static let sampleTimeout: TimeInterval = 8

    private let lock = NSLock()
    private let output: E2EOutput
    private let sampleURL: URL
    private let beforeExit: @Sendable () -> Void
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    private var step = ""
    private var deadline = DispatchTime.distantFuture
    private var pending: [String] = []

    /// `beforeExit` runs on the watchdog's queue after the TIMEOUT line and the stack sample, just before the
    /// process exits.
    init(output: E2EOutput, sampleURL: URL, beforeExit: @escaping @Sendable () -> Void = {}) {
        self.output = output
        self.sampleURL = sampleURL
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

    /// The tests that have not run yet, listed as `NOT RUN` if the watchdog fires.
    func setPending(_ tests: [String]) {
        lock.withLock { pending = tests }
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
        for test in pending { output.line("NOT RUN \(test)") }
        writeSample()
        // Bounded, so a stuck beforeExit (for example a terminal that stopped reading) cannot keep the run alive.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [beforeExit] in
            beforeExit()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + Self.beforeExitTimeout)
        _exit(Self.timeoutExitCode)
    }

    /// Writes a stack sample of every thread of the app with /usr/bin/sample, bounded by `sampleTimeout`.
    private func writeSample() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier), String(Self.sampleSeconds), "-file", sampleURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            output.line("stack sample: not written: \(error.localizedDescription)")
            return
        }
        if finished.wait(timeout: .now() + Self.sampleTimeout) == .timedOut {
            process.terminate()
            output.line("stack sample: not written: sample took longer than \(Int(Self.sampleTimeout)) seconds")
        } else {
            output.line("stack sample: \(sampleURL.path)")
        }
    }
}
