import AppKit
import BowCore

/// The view a window shows its current tab in. It shows one tab's web view at a time; the tabs it does not show
/// keep their pages alive, out of every view. Showing a tab another surface view shows moves its page here, by
/// plain reparenting, so the page keeps its state (W1 criterion 4).
@MainActor
public final class WebKitSurfaceView: NSView {
    private weak var shownTab: WebKitTab?

    public override init(frame: NSRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Shows `tab`, detaching the tab shown before. `tab` must come from the BowWebKit engine; a closed tab is not
    /// shown, and the view is then empty.
    public func show(_ tab: any EngineTab) {
        guard let tab = tab as? WebKitTab else {
            assertionFailure("tab \(tab.tabID) did not come from the BowWebKit engine")
            return
        }
        if shownTab === tab, let webView = tab.webView, webView.superview === self { return }
        detach()
        guard let webView = tab.webView else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        shownTab = tab
    }

    /// True while `tab` is the one this view shows.
    public func isShowing(_ tab: any EngineTab) -> Bool {
        guard let shownTab, let tab = tab as? WebKitTab, shownTab === tab else { return false }
        return tab.webView?.superview === self
    }

    /// True while the view shows a tab's page.
    public var showsTab: Bool { shownTab?.webView?.superview === self }

    /// Takes the shown tab's page out of the view; the page stays alive.
    public func detach() {
        if let webView = shownTab?.webView, webView.superview === self { webView.removeFromSuperview() }
        shownTab = nil
    }

    /// Gives the shown tab's page keyboard focus.
    public func focusShownTab() {
        guard let webView = shownTab?.webView, webView.superview === self else { return }
        window?.makeFirstResponder(webView)
    }
}
