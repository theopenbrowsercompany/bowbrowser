import AppKit

/// A browser window holding one web view.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    let webView: BowWebView
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?

    /// Opens `url` in a new centered window, or in `window` when given (e2e runs pass an off-screen one),
    /// which is not cascaded: the caller places it.
    init(url: URL, window givenWindow: BrowserWindow? = nil) {
        let window =
            givenWindow
            ?? BrowserWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: Self.styleMask,
                backing: .buffered,
                defer: false
            )
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        webView = BowWebView(frame: NSRect(origin: .zero, size: contentSize), url: url.absoluteString)
        window.title = "Bow"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        if givenWindow == nil { window.center() }
        super.init(window: window)
        if givenWindow != nil {
            // A window controller cascades its window to a new spot; the caller places a given window itself.
            shouldCascadeWindows = false
        }
        window.delegate = self

        webView.onTitleChange = { [weak window] title in
            window?.title = title.isEmpty ? "Bow" : title
        }
        // The browser closes first (from this window's close button or from quitting); the window follows.
        webView.onBrowserClosed = { [weak window] in
            window?.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        webView.shouldCloseWindow()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// A window whose close requests (close button, Cmd+W, Window > Close) wait for the page to close first.
/// AppKit's `performClose(_:)` plays the alert sound whenever `windowShouldClose(_:)` says no, which here only
/// means "the page is closing, the window follows", so this asks the delegate without the sound.
class BrowserWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}
