import AppKit

// The popup windows area of the adapter: E2EPopupWindowsApp over BowPopupParking's hosting hook, which has the
// engine create a test's popups in E2EPopupHostWindow windows off screen, and the engine's own sheet on them,
// answered by pressing its buttons as a person does.

/// The hosted popup windows of the running test, newest last.
@MainActor
private enum E2EPopupHosting {
    static var windows: [E2EPopupHostWindow] = []
    static var openWindows: [E2EPopupHostWindow] { windows.filter(\.isVisible) }

    /// A new off screen window for a popup, ordered in without focus, or nil (the popup is parked) if it would show
    /// on a screen.
    static func newWindow() -> NSView? {
        let offset = CGFloat(windows.count) * 40
        let window = E2EPopupHostWindow(
            frame: NSRect(x: -24_000 + offset, y: -21_000 - offset, width: 480, height: 360))
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }), !window.canBecomeKey
        else { return nil }
        window.orderFrontRegardless()
        windows.append(window)
        return window.contentView
    }
}

extension E2ETestApp: E2EPopupWindowsApp {
    func hostPopupWindows() throws {
        try adapter.requireActive(token, "host popup windows")
        let token = token
        let adapter = adapter
        // The engine asks on the main thread, as each popup is created.
        BowPopupParking.hostPopups {
            MainActor.assumeIsolated {
                // A popup opened after its test ended is parked, as in every other test.
                guard (try? adapter.requireActive(token, "host a popup window")) != nil else { return nil }
                return E2EPopupHosting.newWindow()
            }
        }
    }

    func stopHostingPopupWindows() {
        BowPopupParking.hostPopups(in: nil)
        for window in E2EPopupHosting.openWindows {
            if let view = window.contentView { _ = BowPopupParking.closePopup(in: view) }
        }
        E2EPopupHosting.windows.removeAll { !$0.isVisible }
    }

    func openPopupWindowCount() throws -> Int {
        try adapter.requireActive(token, "count the popup windows")
        return E2EPopupHosting.openWindows.count
    }

    func popupWindowDialog() throws -> E2EPageDialog? {
        try adapter.requireActive(token, "read the popup window's dialog")
        guard let window = E2EPopupHosting.openWindows.last, let alert = BowPopupParking.dialog(on: window) else {
            return nil
        }
        return E2EPageDialog(
            title: alert.messageText, message: alert.informativeText, buttons: alert.buttons.map(\.title),
            field: (alert.accessoryView as? NSTextField)?.stringValue,
            isAttached: alert.window.sheetParent === window)
    }

    func answerPopupWindowDialog(accept: Bool, text: String?) throws {
        try adapter.requireActive(token, "answer the popup window's dialog")
        guard let window = E2EPopupHosting.openWindows.last, let alert = BowPopupParking.dialog(on: window) else {
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
        guard let view = E2EPopupHosting.openWindows.last?.contentView, BowPopupParking.closePopup(in: view) else {
            throw E2EError("no hosted popup is open")
        }
    }
}
