import AppKit

/// A browser window holding one web view.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let webView: BowWebView

    init(url: URL) {
        webView = BowWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), url: url.absoluteString)
        let window = NSWindow(
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        webView.shouldCloseWindow()
    }
}
