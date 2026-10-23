import Foundation

/// Split views as a test drives them: the sidebar's split items, the panes they show, the panes' close buttons and
/// dividers. E2E/Harness/E2EAppAdapter+Split.swift implements it; every action is refused once the test has ended.
/// Sidebar menus and rows are driven through `E2EFoldersApp`, panes through `E2EPanesApp`.
@MainActor
protocol E2ESplitApp: E2EApp {
    /// The splits of `page`'s window and what its panes show.
    func splitState(of page: any E2EPage) throws -> E2ESplitState
    /// Points what new tabs of `page`'s window open (the window's `newTabURL`) at `url`, so a test opens no outside
    /// page.
    func setNewTabURL(_ url: URL, of page: any E2EPage) throws
    /// Clicks outline row `row` (a tab or split row) of `page`'s window, as the outline's click action does.
    func clickSplitSidebarRow(_ row: Int, in page: any E2EPage) throws
    /// Presses the close button of the pane at `index` in `page`'s window. Throws when that pane has none.
    func clickPaneCloseButton(at index: Int, besides page: any E2EPage) throws
    /// Moves the divider after pane `index` of `page`'s window so the panes before it take `fraction` of the width,
    /// as a drag does: the panes take their new frames and the split view tells its delegate that divider moved.
    func dragPaneDivider(_ index: Int, to fraction: Double, besides page: any E2EPage) throws
    /// Closes `page`'s window, adds to its sidebar file a split with no tabs and a split holding only the tab titled
    /// `lone` (both in the Space's today section), and opens the window again on that file as the app does at
    /// launch, which repairs it. Returns the reopened window's page.
    func relaunchWithBrokenSplits(of page: any E2EPage, lone: String) async throws -> any E2EPage
}

/// A window's splits and panes, read back from its store and its page area.
struct E2ESplitState: CustomStringConvertible {
    /// The title of the tab each pane shows, leading to trailing.
    var panes: [String]
    /// The position of the focused pane.
    var focusedIndex: Int
    /// The title of the sidebar's active tab, nil when none is active.
    var activeTitle: String?
    /// Each split in the sidebar of the Space on screen, in sidebar order, as its tabs' titles in pane order.
    var splits: [[String]]
    /// The title of each split's saved focused pane.
    var splitFocus: [String]
    /// Each split's saved width factors, in pane order.
    var splitWidths: [[Double]]
    /// How many items sit right in the today section of the Space on screen (a split counts as one).
    var todayItems: Int
    /// The titles of those items ("Split View" for a split).
    var today: [String]
    /// How many tabs, folders and splits the sidebar holds.
    var itemCount: Int
    /// How many pane close buttons show.
    var closeButtons: Int
    /// Whether the window's keyboard focus is in the focused pane's page.
    var keyboardInFocused: Bool

    var description: String {
        let widths = splitWidths.map { "[" + $0.map { String(format: "%.2f", $0) }.joined(separator: ",") + "]" }
        return "panes=[\(panes.joined(separator: ","))] focused=\(focusedIndex) active=\(activeTitle ?? "none")"
            + " splits=\(splits) focus=\(splitFocus) widths=[\(widths.joined(separator: ","))]"
            + " today=\(today) items=\(itemCount) closeButtons=\(closeButtons) keyboard=\(keyboardInFocused)"
    }
}
