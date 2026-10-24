import AppKit
import BowCore
import WebKit

// Web Inspector through WebKit's private `_WKInspector` (`WebKitSPI`). It docks beside the page's attachment view
// (the web view itself unless `setInspectorAttachmentView(_:)` names another), inside the tab's own window, the way
// Safari docks it; WebKit opens it in a window of its own only when that view is too small to share.

extension WebKitTab {
    /// Opens Web Inspector, or leaves it open. `point` is not used: WebKit has no call to inspect the element at a
    /// point, so the inspector opens on the page as a whole (Inspect Element in the page's context menu does that).
    func showInspector(inspectingAt point: PagePoint?) {
        guard !isClosed, let webView else { return }
        // WebKit opens no inspector for a page without developer extras; they also add Inspect Element to the
        // page's context menu, as Arc has it. The web view's preferences are its own live object, shared with no
        // other tab.
        WebKitSPI.setDeveloperExtrasEnabled(webView.configuration.preferences, true)
        WebKitSPI.setInspectorShown(webView, true)
    }

    func closeInspector() {
        guard let webView else { return }
        WebKitSPI.setInspectorShown(webView, false)
    }

    /// WebKit's own answer, so closing the inspector with its own close button counts too; false once the tab
    /// closed and where WebKit dropped the private inspector.
    var hasInspector: Bool {
        guard !isClosed, let webView else { return false }
        return WebKitSPI.inspectorVisible(webView) ?? false
    }

    /// Docks Web Inspector beside `view`, which must share a superview with room for it; nil docks it beside the
    /// web view again. Applies to the current web view only.
    func setInspectorAttachmentView(_ view: NSView?) {
        guard let webView else { return }
        WebKitSPI.setInspectorAttachment(webView, view)
    }
}
