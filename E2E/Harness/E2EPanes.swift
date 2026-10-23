import Foundation

/// The window's panes as a test sees them: one to four tabs side by side in the page area, one focused, through
/// `BrowserWindowController.showPanes` and `focusPane`. E2E/Harness/E2EAppAdapter+Panes.swift implements it; every
/// action is refused once the test has ended.
@MainActor
protocol E2EPanesApp: E2EApp {
    /// Shows the tabs of `pages` (all in one window) side by side in that order, with `focused`'s tab in focus.
    /// Returns what `showPanes` returned.
    /// `fractions` gives each pane's share of the width (nil for equal panes).
    func showPanes(_ pages: [any E2EPage], focused: any E2EPage, fractions: [Double]?) throws -> Bool
    /// Focuses the pane at `index` in `page`'s window the way a focus shortcut does. Returns what `focusPane` returned.
    func focusPane(at index: Int, besides page: any E2EPage) throws -> Bool
    /// Presses and releases the mouse at the middle of the pane at `index` in `page`'s window, through the window's
    /// own event dispatch, as a click does.
    func clickPane(at index: Int, besides page: any E2EPage) throws
    /// Places a plain view over the page area of `page`'s window through `addPageOverlay`, and returns its tag.
    func addPageOverlay(besides page: any E2EPage) throws -> Int
    /// The page area of `page`'s window as it is now.
    func panes(besides page: any E2EPage) throws -> E2EPaneState
}

/// The page area's panes, read back from the window.
struct E2EPaneState: CustomStringConvertible {
    /// The title of the tab each pane shows, leading to trailing ("-" for a pane showing none).
    var titles: [String]
    /// The position of the focused pane.
    var focusedIndex: Int
    /// The title of the window's selected tab, nil when it has none.
    var selectedTitle: String?
    /// The title of the sidebar's active tab, nil when none is active.
    var activeTitle: String?
    /// Each pane's frame in the page area, leading to trailing.
    var frames: [CGRect]
    /// The page area's size.
    var pageSize: CGSize
    /// The panes drawn with the focus outline.
    var outlined: [Int]
    /// Whether the window's keyboard focus is in the focused pane's page.
    var keyboardInFocused: Bool
    /// The tag of the page area's frontmost view, 0 when it has none.
    var frontmostTag: Int

    /// Whether the panes sit side by side in order, top to bottom of the page area, and fill its width with only the
    /// dividers between them.
    func fillsWidth() -> Bool {
        guard let first = frames.first, let last = frames.last else { return false }
        let ordered = zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 && $1.minX - $0.maxX < 3 }
        let fullHeight = frames.allSatisfy { abs($0.height - pageSize.height) < 1 }
        return ordered && fullHeight && first.minX < 1 && abs(last.maxX - pageSize.width) < 1
    }

    /// Whether the panes fill the width (`fillsWidth`), each within `tolerance` points of an equal share.
    func fillsEqually(tolerance: CGFloat = 2) -> Bool {
        let share = frames.map(\.width).reduce(0, +) / CGFloat(max(frames.count, 1))
        return fillsWidth() && frames.allSatisfy { abs($0.width - share) <= tolerance }
    }

    var description: String {
        let sizes = frames.map { "\(Int($0.minX))+\(Int($0.width))" }.joined(separator: ",")
        return "panes=[\(titles.joined(separator: ","))] focused=\(focusedIndex) selected=\(selectedTitle ?? "none")"
            + " active=\(activeTitle ?? "none") frames=[\(sizes)] page=\(Int(pageSize.width))x\(Int(pageSize.height))"
            + " outlined=\(outlined) keyboard=\(keyboardInFocused) front=\(frontmostTag)"
    }
}
