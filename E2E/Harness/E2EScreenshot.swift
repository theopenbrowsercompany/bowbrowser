import AppKit

/// Screenshots of a page's window as evidence for agents and the maintainer, never for pixel comparisons.
///
/// The window's AppKit views come from `cacheDisplay(in:to:)`, in which Chromium's layer renders blank, and the
/// web content from DevTools `Page.captureScreenshot`; the web image is drawn into the web view's rect. Neither
/// needs the Screen Recording permission, and both work on the off-screen window.
@MainActor
enum E2EScreenshot {
    /// A PNG of `page`'s window, title bar included.
    static func png(_ page: any E2EPage) async throws -> Data {
        guard let contentView = page.contentView, let window = contentView.window,
            let windowContent = window.contentView
        else {
            throw E2EError("the page's window has closed")
        }
        let web = try await webContent(page)

        // The frame view above the content view draws the title bar.
        let root = windowContent.superview ?? windowContent
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw E2EError("cannot make a bitmap of the window")
        }
        root.cacheDisplay(in: root.bounds, to: image)

        var webRect = root.convert(contentView.bounds, from: contentView)
        if root.isFlipped { webRect.origin.y = root.bounds.height - webRect.maxY }
        guard let context = NSGraphicsContext(bitmapImageRep: image) else {
            throw E2EError("cannot draw into the window bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The web image is in device pixels; drawing it into the rect in points scales it to the bitmap.
        web.draw(in: webRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = image.representation(using: .png, properties: [:]) else {
            throw E2EError("cannot encode the screenshot as PNG")
        }
        return png
    }

    /// The page's visible web content, from DevTools.
    private static func webContent(_ page: any E2EPage) async throws -> NSImage {
        let response = try await page.devTools("Page.captureScreenshot", ["format": "png"])
        guard let base64 = response["data"] as? String, let data = Data(base64Encoded: base64),
            let image = NSImage(data: data)
        else {
            throw E2EError("Page.captureScreenshot returned no image")
        }
        return image
    }
}
