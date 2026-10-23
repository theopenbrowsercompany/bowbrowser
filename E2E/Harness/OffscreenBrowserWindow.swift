import AppKit

/// A browser window for e2e runs that stays where it is put, even off every screen, and never takes focus,
/// so it composites like a visible window while nothing shows on the maintainer's screen.
final class OffscreenBrowserWindow: BrowserWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Otherwise AppKit writes Saved Application State for the real bundle ID.
    override var isRestorable: Bool {
        get { false }
        set {}
    }

    // AppKit calls this to pull windows back onto a screen; keep the frame as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
