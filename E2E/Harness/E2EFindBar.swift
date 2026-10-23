import Foundation

// The find in page bar as a test sees it. It opens through the app's Find menu item, and keys reach its field
// the way the keyboard sends them (key events to the field editor), never through DevTools.

/// A key `E2EFindBar.press(_:)` can send to the find bar's field.
enum E2EFindKey {
    case enter
    case shiftEnter
    case escape
}

/// What a find in page search reported.
struct E2EFindResult: Equatable {
    var matches: Int
    var active: Int
    var isFinal: Bool
}

/// The find bar of a page's window, opened with `E2EPage.openFindBar()`.
@MainActor
protocol E2EFindBar: AnyObject {
    /// True while the bar shows.
    var isShown: Bool { get }
    /// True while the keyboard is in the bar's field.
    var hasKeyboard: Bool { get }
    /// The count the bar shows, such as "1 of 3", or "" when it shows none.
    var count: String { get }
    /// The text in the bar's field.
    var text: String { get }
    /// The last result the page's tab reported for a search, or nil before the first one.
    var lastResult: E2EFindResult? { get }
    /// Types `text` into the field, one key press per character.
    func type(_ text: String) throws
    /// Presses `key` in the field.
    func press(_ key: E2EFindKey) throws
}

extension E2EFindBar {
    /// Waits until the bar shows `count` for a final result, checking every 10 ms, and throws with what it shows
    /// instead when that takes longer than `timeout` seconds.
    func waitForCount(_ count: String, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(self.count == count && lastResult?.isFinal == true) {
            guard Date() < deadline else {
                let result = lastResult.map { "\($0.active) of \($0.matches)\($0.isFinal ? " final" : "")" } ?? "none"
                throw E2EError(
                    "the find bar shows \"\(self.count)\", not \"\(count)\" (last result: \(result), field: \"\(text)\")"
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
