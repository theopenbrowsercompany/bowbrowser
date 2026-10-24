import Foundation

/// Polls `condition` every 20 ms until it holds, for at most `timeout` seconds. Never a fixed sleep: it returns as
/// soon as the state is there. A condition that throws counts as not yet (a page read can fail while a navigation
/// replaces the page), and the timeout error names the last such error, so it is never lost.
@MainActor
func waitUntil(_ what: String, timeout: Double = 10, _ condition: () async throws -> Bool) async throws {
    _ = try await waitFor(what, timeout: timeout) { try await condition() ? true : nil }
}

/// Polls `value` until it returns non-nil, for at most `timeout` seconds; errors as in `waitUntil`.
@MainActor
func waitFor<T>(_ what: String, timeout: Double = 10, _ value: () async throws -> T?) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: (any Error)?
    while true {
        do {
            if let result = try await value() { return result }
            lastError = nil
        } catch {
            lastError = error
        }
        if Date() > deadline {
            let reason = lastError.map { "; the last check threw \($0)" } ?? ""
            throw TestError("timed out after \(timeout) s waiting for \(what)\(reason)")
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
