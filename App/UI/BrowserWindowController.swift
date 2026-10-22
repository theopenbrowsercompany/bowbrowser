import AppKit

/// A browser window holding one web view.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let webView: BowWebView
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?

    init(url: URL) {
        webView = BowWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), url: url.absoluteString)
        let window = BrowserWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bow"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        super.init(window: window)
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
final class BrowserWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}
