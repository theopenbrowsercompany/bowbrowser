import Foundation

/// Lets one test at a time drive real pointer or key input. Swift Testing runs suites side by side in one process,
/// and the key window state and events one suite's input needs reach WebKit's hover handling in another suite's
/// window (HoverStatusTests lost pointer moves while EditedFormTests typed), so tests that send input hold this.
@MainActor
enum InputLock {
    private static var isHeld = false

    /// Runs `body` once no other test holds the lock, holding it meanwhile.
    static func run<T>(_ body: () async throws -> T) async throws -> T {
        // Wait for the holder to let go: a lock, not a fixed delay (each turn checks again after 10 ms).
        while isHeld { try await Task.sleep(for: .milliseconds(10)) }
        isHeld = true
        defer { isHeld = false }
        return try await body()
    }
}
