import AppKit

/// Screenshots of a page's window as evidence for agents and the maintainer, never for pixel comparisons.
///
/// The window's AppKit views come from `cacheDisplay(in:to:)`, in which Chromium's layer renders blank, and the
/// web content from DevTools `Page.captureScreenshot`; the web image is drawn into the web view's rect, and views
/// floating over the web view (such as the find bar) are drawn again on top. Neither needs the Screen Recording
/// permission, and both work on the off-screen window.
///
/// Every screenshot is drawn at `scale` pixels per point (2) whatever screen the window is on, so a 1200 by 800
/// point window is always a 2400 by 1600 pixel PNG. On a screen of scale 1 the web content comes at 1 pixel per
/// point and is drawn scaled up.
@MainActor
enum E2EScreenshot {
    /// Pixels per point of every screenshot.
    static let scale: CGFloat = 2

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
        let image = try bitmap(of: root)

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
            let overlayImage: NSBitmapImageRep
            do { overlayImage = try bitmap(of: overlay) } catch { continue }
            var rect = root.convert(overlay.bounds, from: overlay)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            overlayImage.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try encode(image)
    }

    /// A PNG of `window` without web content, for a window that shows no page (the empty state) or a part of the
    /// window with no web content in it. `crop`, in points in the coordinates of the window's frame view (the
    /// content view's superview), cuts the screenshot to that rect; nil keeps the whole window.
    static func png(window: NSWindow, crop: NSRect? = nil) throws -> Data {
        guard let windowContent = window.contentView else { throw E2EError("the window has no content") }
        let root = windowContent.superview ?? windowContent
        let image = try bitmap(of: root)
        guard let crop else { return try encode(image) }
        let bounds = root.bounds
        var rect = crop.intersection(bounds)
        if root.isFlipped { rect.origin.y = bounds.height - rect.maxY }
        guard !rect.isEmpty, let whole = image.cgImage else { throw E2EError("the crop \(crop) misses the window") }
        // CGImage rows run from the top.
        let pixels = CGRect(
            x: (rect.minX * scale).rounded(), y: ((bounds.height - rect.maxY) * scale).rounded(),
            width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        guard let cut = whole.cropping(to: pixels) else { throw E2EError("cannot crop the window bitmap") }
        let piece = NSBitmapImageRep(cgImage: cut)
        piece.size = rect.size
        return try encode(piece)
    }

    /// A bitmap of `view` at `scale` pixels per point, in sRGB, with the view drawn into it.
    private static func bitmap(of view: NSView) throws -> NSBitmapImageRep {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
            let blank = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let image = blank.retagging(with: .sRGB)
        else {
            throw E2EError("cannot make a bitmap of \(type(of: view)) sized \(size)")
        }
        image.size = size
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    private static func encode(_ image: NSBitmapImageRep) throws -> Data {
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

    /// The page's visible web content, from the page driver.
    private static func webContent(_ page: any E2EPage) async throws -> NSImage {
        try await page.screenshot()
    }
}
