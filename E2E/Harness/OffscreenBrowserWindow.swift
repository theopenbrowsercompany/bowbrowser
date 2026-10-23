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

    // AppKit also moves a window onto a screen to show a sheet on it; keep it off every screen.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(E2EOffscreenFrame.kept(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(E2EOffscreenFrame.kept(frameRect), display: displayFlag, animate: animateFlag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(E2EOffscreenFrame.kept(NSRect(origin: point, size: frame.size)).origin)
    }
}

/// Where an e2e window may go: anywhere off every screen.
@MainActor
enum E2EOffscreenFrame {
    /// `frame`, or the same size at the e2e windows' place far from every screen when any part of it would show on
    /// one.
    static func kept(_ frame: NSRect) -> NSRect {
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return frame }
        return NSRect(origin: E2EAppAdapter.windowFrame.origin, size: frame.size)
    }
}
