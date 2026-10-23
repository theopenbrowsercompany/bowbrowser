import AppKit
import BowCore

/// What the page area shows, pane by pane, for the features that act per pane (permission prompts, the crashed
/// page, find, page dialogs): read from the window core's pane API, deciding nothing.
extension BrowserWindowController {
    /// The tabs the page area shows with their panes' views, in pane order: one, or two to four in a split view.
    var shownPanes: [(tab: any EngineTab, view: NSView)] {
        let tabs = self.tabs
        return paneViews.compactMap { view in tabs.first { view.isShowing($0) }.map { ($0, view as NSView) } }
    }

    /// The view of the pane showing `tab`, nil while no pane shows it.
    func paneView(showing tab: any EngineTab) -> NSView? {
        paneViews.first { $0.isShowing(tab) }
    }
}
