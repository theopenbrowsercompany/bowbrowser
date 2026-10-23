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
    /// Drags the divider after pane `index` of `page`'s window so the panes before it take `fraction` of the length:
    /// `pressPaneDivider`, one `movePaneDivider` and `releasePaneDivider`.
    func dragPaneDivider(_ index: Int, to fraction: Double, besides page: any E2EPage) throws
    /// Presses on a divider of `page`'s window: what the split view's press handling does before it tracks the drag
    /// (never a synthetic mouse down, whose tracking loop would never end).
    func pressPaneDivider(besides page: any E2EPage) throws
    /// One step of a drag: moves the divider after pane `index` so the panes before it take `fraction` of the length
    /// (the width side by side, the height stacked), as AppKit's tracking does: the panes take their new frames and
    /// the split view tells its delegate that divider moved.
    func movePaneDivider(_ index: Int, to fraction: Double, besides page: any E2EPage) throws
    /// Lets go of the divider: what the split view's press handling does once its tracking returns.
    func releasePaneDivider(besides page: any E2EPage) throws
    /// Chooses View > Add Top Split (`top`) or Add Bottom Split in `page`'s window through the app's menu, as a click
    /// on the item does. Throws when the item is missing or disabled.
    func chooseStackedSplit(top: Bool, in page: any E2EPage) throws
    /// Whether View > Add Split View, Add Top Split and Add Bottom Split are enabled for `page`'s window now.
    func splitMenuItemsEnabled(in page: any E2EPage) throws -> [String: Bool]
    /// Where the window's per-pane UI sits now, in window coordinates.
    func paneOverlays(besides page: any E2EPage) throws -> E2EPaneOverlays
    /// Closes `page`'s window, adds to its sidebar file a split with no tabs and a split holding only the tab titled
    /// `lone` (both in the Space's today section), and opens the window again on that file as the app does at
    /// launch, which repairs it. Returns the reopened window's page.
    func relaunchWithBrokenSplits(of page: any E2EPage, lone: String) async throws -> any E2EPage
}

/// The page UI a window floats over its panes, read back in window coordinates.
struct E2EPaneOverlays: CustomStringConvertible {
    /// Each pane's frame, in pane order.
    var panes: [CGRect]
    /// The find bar's frame while it shows.
    var findBar: CGRect?
    /// The frame of the page dialog's sheet while one is attached to the window.
    var sheet: CGRect?
    /// The permission prompts' frames.
    var prompts: [CGRect]
    /// Whether the window's frame is off every screen.
    var windowOffScreen: Bool

    /// The pane whose frame holds `rect`'s center, nil when none does.
    func pane(holding rect: CGRect?) -> Int? {
        guard let rect else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return panes.firstIndex { $0.contains(center) }
    }

    /// The pane `rect` sits at the top of: its top within `slack` points under the pane's top, its center inside the
    /// pane's width. Nil when none.
    func pane(topOf rect: CGRect?, slack: CGFloat = 40) -> Int? {
        guard let rect else { return nil }
        return panes.firstIndex { pane in
            rect.maxY <= pane.maxY + 2 && pane.maxY - rect.maxY <= slack && rect.midX > pane.minX
                && rect.midX < pane.maxX
        }
    }

    var description: String {
        func text(_ rect: CGRect?) -> String {
            rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
        }
        return "panes=[\(panes.map(text).joined(separator: "; "))] find=\(text(findBar)) sheet=\(text(sheet))"
            + " prompts=[\(prompts.map(text).joined(separator: "; "))] offScreen=\(windowOffScreen)"
    }
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
    /// Each split's saved layout ("horizontal" side by side, "vertical" stacked), in sidebar order.
    var splitOrientations: [String] = []
    /// The titles of the items right in the pinned section of the Space on screen ("Split View" for a split).
    var pinned: [String] = []
    /// How many of the window's tabs have an open page.
    var loadedTabs: Int = 0

    var description: String {
        let widths = splitWidths.map { "[" + $0.map { String(format: "%.2f", $0) }.joined(separator: ",") + "]" }
        return "panes=[\(panes.joined(separator: ","))] focused=\(focusedIndex) active=\(activeTitle ?? "none")"
            + " splits=\(splits) focus=\(splitFocus) widths=[\(widths.joined(separator: ","))]"
            + " layouts=\(splitOrientations) today=\(today) pinned=\(pinned) items=\(itemCount)"
            + " closeButtons=\(closeButtons) keyboard=\(keyboardInFocused) loaded=\(loadedTabs)"
    }
}
