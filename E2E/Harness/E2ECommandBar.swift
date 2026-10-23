import Foundation

// The command bar as a test sees it. It opens through the app's menu (Cmd+T, Cmd+L) or a key the page's tab is sent
// (which the app claims before the page), and keys reach its field the way the keyboard sends them (key events to the
// field editor), never through DevTools.

/// A key `E2ECommandBar.press(_:)` can send to the bar's field.
enum E2ECommandBarKey {
    case up
    case down
    case enter
    case escape
}

/// One row of the command bar.
struct E2ECommandBarRow: Equatable, CustomStringConvertible {
    /// "tab" for an open tab, "history" for a visited page, "navigate" for the typed address, "search" for a search.
    var kind: String
    var title: String
    var url: URL
    /// The Space an open tab lives in, by name; nil for other rows and for a Favorite.
    var space: String?

    /// "tab:A", "history:Visited", "navigate:https://bow.test/x", "search:rust book".
    var description: String { "\(kind):\(kind == "navigate" ? url.absoluteString : title)" }
}

/// The command bar of a page's window (`E2ECommandBarApp.commandBar(of:)`).
@MainActor
protocol E2ECommandBar: AnyObject {
    /// True while the bar shows.
    var isShown: Bool { get }
    /// True while the keyboard is in the bar's field.
    var hasKeyboard: Bool { get }
    /// The text in the bar's field.
    var text: String { get }
    /// True when the field's whole text is selected (and it holds some).
    var isTextSelected: Bool { get }
    /// The rows shown, best first.
    var rows: [E2ECommandBarRow] { get }
    /// The highlighted row, nil when no row shows.
    var selectedRow: Int? { get }
    /// The text whose results are complete (every source answered or timed out), nil while a query runs.
    var settledQuery: String? { get }
    /// Types `text` into the field, one key press per character.
    func type(_ text: String) throws
    /// Presses `key` in the field.
    func press(_ key: E2ECommandBarKey) throws
    /// Clicks the window outside the bar's panel, over the page.
    func clickOutside() throws
}

extension E2ECommandBar {
    /// Waits until the results for the field's current text are complete, checking every 10 ms, and returns the
    /// rows. Throws with what the bar shows when that takes longer than the step allows.
    @discardableResult
    func waitForResults() async throws -> [E2ECommandBarRow] {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while !(isShown && settledQuery == text) {
            guard Date() < deadline else {
                throw E2EError(
                    "the command bar's results for \"\(text)\" did not settle (shown=\(isShown) "
                        + "settled=\(settledQuery ?? "none") rows=\(rows.map(\.description)))")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return rows
    }
}

/// The app's command bars as a test sees them.
@MainActor
protocol E2ECommandBarApp: E2EApp {
    /// The command bar of the window `page` is in, shown or not.
    func commandBar(of page: any E2EPage) throws -> any E2ECommandBar
    /// The names of the tabs the sidebar of `page`'s window lists in the Space on screen, in order, with the
    /// active one, and the Space's name: "space=work tabs=[A,B] active=A".
    func tabSummary(of page: any E2EPage) throws -> String
}
