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

    // AppKit also slides a window onto a screen to show a sheet on it; keep it off every screen.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(E2EOffscreenFrame.kept(frameRect, for: self), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(E2EOffscreenFrame.kept(frameRect, for: self), display: displayFlag, animate: animateFlag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(E2EOffscreenFrame.kept(NSRect(origin: point, size: frame.size), for: self).origin)
    }
}

/// Where an e2e window may go: anywhere off every screen.
@MainActor
enum E2EOffscreenFrame {
    /// `frame` for `window` when no part of it, or of the child windows that move along with it, would be on a
    /// screen. Otherwise the move is refused: the window keeps its place with the new size, or goes to the e2e
    /// windows' place far from every screen if even that would show.
    static func kept(_ frame: NSRect, for window: NSWindow) -> NSRect {
        let current = window.frame
        func shows(_ candidate: NSRect) -> Bool {
            let dx = candidate.minX - current.minX
            let dy = candidate.minY - current.minY
            let moved = [candidate] + (window.childWindows ?? []).map { $0.frame.offsetBy(dx: dx, dy: dy) }
            return moved.contains { rect in NSScreen.screens.contains { $0.frame.intersects(rect) } }
        }
        let resized = NSRect(origin: current.origin, size: frame.size)
        for candidate in [frame, resized] where !shows(candidate) { return candidate }
        return NSRect(origin: E2EAppAdapter.windowFrame.origin, size: frame.size)
    }
}
