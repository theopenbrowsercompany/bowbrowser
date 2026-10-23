import AppKit

// The popup windows area of the adapter: E2EPopupWindowsApp over BowPopupParking's hosting hook, which has the
// engine create a test's popups in E2EPopupHostWindow windows off screen, and the engine's own sheet on them,
// answered by pressing its buttons as a person does.

/// The hosted popup windows, each with the test that hosted it, newest last, and the test hosting now.
@MainActor
private enum E2EPopupHosting {
    static var windows: [(token: Int, window: E2EPopupHostWindow)] = []
    static var hostingToken: Int?

    /// The open hosted windows of the test with `token`, newest last; never another test's.
    static func openWindows(of token: Int) -> [E2EPopupHostWindow] {
        windows.filter { $0.token == token && $0.window.isVisible }.map(\.window)
    }

    /// A new off screen window for a popup of the test with `token`, ordered in without focus, or nil (the popup is
    /// parked) if it would show on a screen.
    static func newWindow(for token: Int) -> NSView? {
        windows.removeAll { !$0.window.isVisible }
        let offset = CGFloat(windows.count) * 40
        let window = E2EPopupHostWindow(
            frame: NSRect(x: -24_000 + offset, y: -21_000 - offset, width: 480, height: 360))
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            window.close()
            return nil
        }
        window.orderFrontRegardless()
        windows.append((token, window))
        return window.contentView
    }
}

extension E2ETestApp: E2EPopupWindowsApp {
    func hostPopupWindows() throws {
        try adapter.requireActive(token, "host popup windows")
        let token = token
        let adapter = adapter
        E2EPopupHosting.hostingToken = token
        // The engine asks on the main thread, as each popup is created.
        BowPopupParking.hostPopups {
            MainActor.assumeIsolated {
                // A popup opened after its test ended is parked, as in every other test.
                guard (try? adapter.requireActive(token, "host a popup window")) != nil else { return nil }
                return E2EPopupHosting.newWindow(for: token)
            }
        }
    }

    func stopHostingPopupWindows() {
        // A late call from a test that ended (a timed out step unwinding) leaves a later test's hosting alone.
        if E2EPopupHosting.hostingToken == token {
            E2EPopupHosting.hostingToken = nil
            BowPopupParking.hostPopups(in: nil)
        }
        for window in E2EPopupHosting.openWindows(of: token) {
            if let view = window.contentView { _ = BowPopupParking.closePopup(in: view) }
        }
    }

    func openPopupWindowCount() throws -> Int {
        try adapter.requireActive(token, "count the popup windows")
        return E2EPopupHosting.openWindows(of: token).count
    }

    func popupWindowDialog() throws -> E2EPageDialog? {
        try adapter.requireActive(token, "read the popup window's dialog")
        guard let window = E2EPopupHosting.openWindows(of: token).last, let alert = BowPopupParking.dialog(on: window)
        else {
            return nil
        }
        return E2EPageDialog(
            title: alert.messageText, message: alert.informativeText, buttons: alert.buttons.map(\.title),
            field: (alert.accessoryView as? NSTextField)?.stringValue,
            isAttached: alert.window.sheetParent === window)
    }

    func answerPopupWindowDialog(accept: Bool, text: String?) throws {
        try adapter.requireActive(token, "answer the popup window's dialog")
        guard let window = E2EPopupHosting.openWindows(of: token).last, let alert = BowPopupParking.dialog(on: window)
        else {
            throw E2EError("no dialog is up on a popup window")
        }
        if let text {
            guard let field = alert.accessoryView as? NSTextField else {
                throw E2EError("the popup window's dialog has no text field")
            }
            field.stringValue = text
        }
        let buttons = alert.buttons
        guard let button = accept ? buttons.first : buttons.dropFirst().first else {
            throw E2EError("the popup window's dialog has no \(accept ? "OK" : "Cancel") button")
        }
        button.performClick(nil)
    }

    func closePopupWindowAsQuitDoes() throws {
        try adapter.requireActive(token, "close the popup window")
        guard let view = E2EPopupHosting.openWindows(of: token).last?.contentView, BowPopupParking.closePopup(in: view)
        else {
            throw E2EError("no hosted popup is open")
        }
    }
}
