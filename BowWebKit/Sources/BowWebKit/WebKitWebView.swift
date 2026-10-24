import AppKit
import WebKit

/// The web view of every Bow tab.
final class WebKitWebView: WKWebView {
    /// A click into an inactive window reaches the page, not only the window: the W1 spike found WebKit otherwise
    /// drops the first click into an inactive app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
