import AppKit

/// Popup windows of the engine's own (a sized `window.open`) hosted in real off screen windows for one test, instead
/// of being parked in no window as every other test has them: their dialogs come up as sheets on their window, and
/// their close goes through the window as a popup window's does. E2E/Harness/E2EAppAdapter+PopupWindows.swift
/// implements it; every action but `stopHostingPopupWindows` is refused once the test has ended.
@MainActor
protocol E2EPopupWindowsApp: E2EApp {
    /// From now on, each popup the engine opens in a window of its own opens in a new off screen window that never
    /// takes focus. Call `stopHostingPopupWindows` before the test ends.
    func hostPopupWindows() throws
    /// Parks popups again and asks every hosted popup still open to close as quitting does. Safe to call at any time,
    /// also after the test ended, and more than once.
    func stopHostingPopupWindows()
    /// The page of the newest popup panel over `page`'s window, for input and scripts only (its loads are not
    /// tracked): a sized popup from a click opens in a panel, and the pages a panel's page opens are the engine's
    /// popup windows. Throws when no panel is open.
    func popupPanelPage(besides page: any E2EPage) throws -> any E2EPage
    /// How many hosted popup windows are open.
    func openPopupWindowCount() throws -> Int
    /// The dialog sheet up on the newest open hosted popup window, or nil when none is.
    func popupWindowDialog() throws -> E2EPageDialog?
    /// Presses OK on the sheet up on the newest open hosted popup window, typing `text` into a prompt's field first
    /// when given, or Cancel when `accept` is false. Throws when no sheet is up.
    func answerPopupWindowDialog(accept: Bool, text: String?) throws
    /// Asks the popup in the newest open hosted popup window to close with the request quitting makes of every
    /// browser. Throws when no hosted popup is open.
    func closePopupWindowAsQuitDoes() throws
}

/// An off screen window hosting one popup page for a test: titled and closable like the engine's own popup windows,
/// so the engine's close (performClose:) and a sheet go through the same AppKit paths; it stays where it is put and
/// never takes focus. Closing it takes its page's view out, which ends the popup's browser, as closing the engine's
/// own popup window does.
final class E2EPopupHostWindow: NSWindow, NSWindowDelegate {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var isRestorable: Bool {
        get { false }
        set {}
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // AppKit also moves a window onto a screen to show a sheet on it; keep it off every screen.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(E2EOffscreenFrame.kept(frameRect, for: self), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(E2EOffscreenFrame.kept(frameRect, for: self), display: displayFlag, animate: animateFlag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(E2EOffscreenFrame.kept(NSRect(origin: point, size: frame.size), for: self).origin)
    }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        delegate = self
        setFrame(frameRect(forContentRect: frame), display: false)
    }

    func windowWillClose(_ notification: Notification) {
        for view in contentView?.subviews ?? [] { view.removeFromSuperview() }
    }
}
