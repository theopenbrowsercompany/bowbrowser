import AppKit
import BowCore

/// A page's alert, confirm and prompt, scoped to its tab as Chromium scopes them (`PageDialogPolicy` holds the
/// rules): a sheet on the window while the window shows the tab that asked, in any pane of a split view, dropping
/// from the top of that tab's pane, never an app modal panel. An alert from a
/// tab the window does not show is answered at once and comes up when its tab is shown; a confirm or prompt from one
/// is cancelled. Switching tabs, a new navigation, closing the tab or the window, and quitting take the sheet down.
/// The tab's "leave this site?" prompt is not one of these: the tab asks it itself.
/// The sheets themselves are `PageDialogSheets`, which a popup panel uses for its own page too.
@MainActor
final class PageDialogsFeature: NSResponder, BrowserWindowFeature {
    private let sheets: PageDialogSheets
    private unowned let window: BrowserWindowController

    /// The sheet on the window, if a dialog is up.
    var sheet: PageDialogSheets.Sheet? { sheets.sheet }

    init(window: BrowserWindowController) {
        self.window = window
        sheets = PageDialogSheets(window: window.window)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether `tab` has a dialog up or waiting for its tab to be shown, which unloading it would take away unseen.
    func hasDialog(for tab: any EngineTab) -> Bool {
        sheets.hasDialog(for: tab.tabID)
    }

    func runDialog(_ dialog: PageDialog, for tab: any EngineTab) async -> PageDialogAnswer? {
        await sheets.run(dialog, for: tab.tabID)
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        // Every pane on screen counts as shown, so a dialog from an unfocused pane comes up at once over its pane.
        guard let tab, !tab.isClosed else {
            sheets.show([])
            return
        }
        sheets.show(window.shownPanes.map(\.tab.tabID))
    }

    /// The dialog's sheet drops from the top of the pane that asked, centered on it, rather than from the top of the
    /// whole window: with a split view showing, it sits over its own pane.
    func positionSheet(_ sheet: NSWindow, proposed: NSRect) -> NSRect? {
        guard let up = sheets.sheet, up.alert.window === sheet, let tabID = sheets.sheetTab,
            let pane = window.shownPanes.first(where: { $0.tab.tabID == tabID })?.view, pane.window != nil
        else { return nil }
        let frame = pane.convert(pane.bounds, to: nil)
        // AppKit drops the sheet from the rect's top edge, centered on its width.
        return NSRect(x: frame.minX, y: min(frame.maxY, proposed.origin.y), width: frame.width, height: 0)
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        // A dialog belongs to the page that asked; a navigation leaves it (as Chromium, also one that never
        // commits), and a page whose render process ended can no longer hear the answer.
        switch event {
        case .didStartNavigation, .renderProcessGone: sheets.navigated(tab.tabID)
        default: break
        }
    }

    func tabDidClose(_ tab: any EngineTab) {
        sheets.closed(tab.tabID)
    }
}
