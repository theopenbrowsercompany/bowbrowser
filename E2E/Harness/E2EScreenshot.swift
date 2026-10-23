import AppKit

/// Screenshots of a page's window as evidence for agents and the maintainer, never for pixel comparisons.
///
/// The window's AppKit views come from `cacheDisplay(in:to:)`, in which Chromium's layer renders blank, and the
/// web content from DevTools `Page.captureScreenshot`; the web image is drawn into the web view's rect, and views
/// floating over the web view (such as the find bar) are drawn again on top. Neither needs the Screen Recording
/// permission, and both work on the off-screen window.
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
        // A page area with rounded corners clips the web content to them, so the screenshot does too.
        NSGraphicsContext.saveGraphicsState()
        if let clip = roundedClip(of: contentView, in: root) { clip.addClip() }
        // The web image is in device pixels; drawing it into the rect in points scales it to the bitmap.
        web.draw(in: webRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        // Views floating over the web view (such as the find bar, or the command bar over the page area) were
        // covered by the web image; draw them again.
        for overlay in overlays(above: contentView, in: windowContent) {
            guard let overlayImage = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: overlayImage)
            var rect = root.convert(overlay.bounds, from: overlay)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            overlayImage.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = image.representation(using: .png, properties: [:]) else {
            throw E2EError("cannot encode the screenshot as PNG")
        }
        return png
    }

    /// A PNG of `window` without web content, for a window that shows no page (the empty state).
    static func png(window: NSWindow) throws -> Data {
        guard let windowContent = window.contentView else { throw E2EError("the window has no content") }
        let root = windowContent.superview ?? windowContent
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw E2EError("cannot make a bitmap of the window")
        }
        root.cacheDisplay(in: root.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw E2EError("cannot encode the screenshot as PNG")
        }
        return png
    }

    /// The visible views that draw over `view`: those ordered above it among its siblings, then above each of its
    /// ancestors among theirs, up to `top`, which overlap it.
    private static func overlays(above view: NSView, in top: NSView) -> [NSView] {
        let frame = view.convert(view.bounds, to: nil)
        var found: [NSView] = []
        var current = view
        while current !== top, let parent = current.superview, let index = parent.subviews.firstIndex(of: current) {
            found += parent.subviews[(index + 1)...].filter {
                !$0.isHidden && $0.convert($0.bounds, to: nil).intersects(frame)
            }
            current = parent
        }
        return found
    }

    /// The rounded rect, in `root`'s drawing coordinates, of the nearest ancestor of `view` whose layer clips to
    /// rounded corners; nil when none does.
    private static func roundedClip(of view: NSView, in root: NSView) -> NSBezierPath? {
        var current: NSView? = view
        while let candidate = current, candidate !== root {
            if let layer = candidate.layer, layer.masksToBounds, layer.cornerRadius > 0 {
                var rect = root.convert(candidate.bounds, from: candidate)
                if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
                return NSBezierPath(roundedRect: rect, xRadius: layer.cornerRadius, yRadius: layer.cornerRadius)
            }
            current = candidate.superview
        }
        return nil
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
