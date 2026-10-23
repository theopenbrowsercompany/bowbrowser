import AppKit
import BowCore

// The Little Arc area of the adapter: E2ELittleArcApp over the app delegate's GetURL handler and LittleArcCenter.
// Links are real GetURL Apple Events the delegate takes as the harness's own (as in the links area), so the routing
// decision and the Little Arc window are the app's own. Little Arc windows open off every screen
// (`LittleArcCenter.e2eVisibleFrame`) and never take the keyboard, which the state checks after every step.

extension E2EAppAdapter {
    /// Where e2e runs open Little Arc: far from every screen, below the test windows' place.
    static let littleArcScreen = NSRect(x: -20_000, y: -23_000, width: 1440, height: 900)

    /// Sets up Little Arc for the run before the first link can arrive: off every screen, and links from other apps
    /// open in a browser window unless a test turns the setting on, so the links tests see the window path.
    static func prepareLittleArc() {
        LittleArcCenter.e2eVisibleFrame = littleArcScreen
        LittleArcWindow.e2eKeepFrame = { E2EOffscreenFrame.kept($0, for: $1) }
        AppSettings.defaults.set(false, forKey: LittleArcCenter.opensExternalLinksKey)
    }

    /// Closes the Little Arc windows a test left open, with their pages, and turns the setting back off.
    func closeLittleArc() {
        delegate.appFeatures.require(LittleArcCenter.self).closeAll()
        AppSettings.defaults.set(false, forKey: LittleArcCenter.opensExternalLinksKey)
        delegate.e2eOpenWindow = nil
        delegate.e2eLittleArcClosedDecision = nil
    }

    /// Lets Open in Bow open its window with no browser window open, as the app does, but in an off-screen window
    /// the test tracks and closes, never on a screen.
    func allowLittleArcWindows() {
        delegate.e2eOpenWindow = { [weak self] open in
            let window = OffscreenBrowserWindow(
                contentRect: Self.windowFrame, styleMask: BrowserWindowController.styleMask, backing: .buffered,
                defer: false)
            let controller = try open(window)
            self?.trackAppOpenedWindow(controller)
            // Creating a titled window moves it onto a screen; put it back where it belongs, then order it in
            // without activating the app or becoming key.
            window.setFrame(window.frameRect(forContentRect: Self.windowFrame), display: false)
            window.orderFrontRegardless()
            return controller
        }
    }

    var littleArcCenter: LittleArcCenter { delegate.appFeatures.require(LittleArcCenter.self) }

    func littleArcPanel(_ window: E2ELittleArcWindow) throws -> LittleArcPanel {
        guard let panel = littleArcCenter.panels.first(where: { $0.window.windowNumber == window.windowNumber })
        else { throw E2EError("Little Arc window \(window.windowNumber) is not open") }
        return panel
    }
}

extension E2ETestApp: E2ELittleArcApp {
    func setLittleArcSetting(_ value: Bool?) throws {
        try adapter.requireActive(token, "change the Little Arc setting")
        if let value {
            AppSettings.defaults.set(value, forKey: LittleArcCenter.opensExternalLinksKey)
        } else {
            AppSettings.defaults.removeObject(forKey: LittleArcCenter.opensExternalLinksKey)
        }
    }

    func deliverLinkToLittleArc(_ url: URL) throws -> E2ELittleArcWindow? {
        try adapter.requireActive(token, "deliver a link")
        let center = adapter.littleArcCenter
        adapter.allowLittleArcWindows()
        let before = Set(center.panels.map(ObjectIdentifier.init))
        try E2EAppAdapter.deliver([E2ELink(address: url.absoluteString, sender: true)], delegate: adapter.delegate) {
            _, _, _ in
        }
        guard let panel = center.panels.first(where: { !before.contains(ObjectIdentifier($0)) }) else { return nil }
        guard let tab = panel.tab else { throw E2EError("the new Little Arc window has no page") }
        // The page's calls need a browser window; it is the one the page can move into, else the test's last window
        // (closed when no window is open). Made before the engine reports anything about the new page, which it does
        // on later main thread tasks.
        guard let controller = adapter.delegate.linkWindow() ?? adapter.testControllers.last else {
            throw E2EError("Little Arc opened with no browser window the test opened")
        }
        let page = adapter.track(tab, in: controller, token: token)
        panel.e2eTabEvent = { [weak page] _, event in page?.tabDidReceive(event) }
        return E2ELittleArcWindow(windowNumber: panel.window.windowNumber, page: page)
    }

    func littleArcWindows() throws -> [E2ELittleArcWindowState] {
        try adapter.requireActive(token, "read the Little Arc windows")
        return adapter.littleArcCenter.panels.map { panel in
            let window = panel.window
            let toolbar = panel.toolbar
            // The move menu's Space items, as the menu shows them when opened.
            panel.menuNeedsUpdate(toolbar.moveButton.menu ?? NSMenu())
            let spaces = (toolbar.moveButton.menu?.items ?? []).filter {
                $0.action == #selector(LittleArcPanel.moveToSpace(_:))
            }
            return E2ELittleArcWindowState(
                windowNumber: window.windowNumber,
                isFloatingPanel: window.isFloatingPanel && window.level == .floating
                    && window.collectionBehavior.contains(.moveToActiveSpace),
                intrudes: window.isKeyWindow || window.canBecomeKey
                    || NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                frame: window.frame,
                toolbarHost: toolbar.host.stringValue,
                openEnabled: toolbar.openButton.isEnabled && toolbar.openButton.window === window,
                moveSpaces: spaces.map { $0.isEnabled ? $0.title : "(\($0.title))" },
                showsPage: panel.tab.map { tab in
                    E2EAppAdapter.views(in: window.contentView ?? NSView(), BowWebView.self).contains {
                        $0.isShowing(tab)
                    }
                } ?? false)
        }
    }

    func pressKey(_ key: String, modifiers: E2EKeyModifiers, inLittleArc window: E2ELittleArcWindow) throws -> Bool {
        try adapter.requireActive(token, "press \(modifiers.shortcut(key)) in Little Arc")
        let panel = try adapter.littleArcPanel(window)
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                keyCode: Self.littleArcKeyCodes[key] ?? 0)
        else { throw E2EError("cannot make a key event for \(modifiers.shortcut(key))") }
        // What AppKit calls on the key window for a key with Command or Control, before the page or the menu bar.
        return panel.window.performKeyEquivalent(with: event)
    }

    /// The ANSI key codes of the keys the Little Arc tests press.
    private static let littleArcKeyCodes: [String: UInt16] = [
        "o": 31, "1": 18, "2": 19, "3": 20, "4": 21, "r": 15, "l": 37, "f": 3,
    ]

    func closeLittleArc(_ window: E2ELittleArcWindow) throws {
        try adapter.requireActive(token, "close Little Arc")
        let panel = try adapter.littleArcPanel(window)
        guard let button = panel.window.standardWindowButton(.closeButton) else {
            throw E2EError("Little Arc has no close button")
        }
        button.performClick(nil)
    }

    func untilNoLittleArc() async throws {
        try adapter.requireActive(token, "wait for Little Arc to close")
        // A Little Arc window closes on its page's closed event, which reaches the app on a main thread task of its
        // own.
        let closed = try await E2EWaits.until { adapter.littleArcCenter.panels.isEmpty }
        guard closed else { throw E2EError("\(adapter.littleArcCenter.panels.count) Little Arc windows still open") }
    }

    func browserWindowState(of page: any E2EPage) throws -> E2EBrowserWindowState {
        try adapter.requireActive(token, "read the browser window")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let shown = controller.selectedTab.flatMap { controller.modelID(of: $0) }
        return E2EBrowserWindowState(
            tabs: controller.tabList.tabs.map { "\($0.id)=\($0.url?.absoluteString ?? "")" },
            shownTab: shown.map { "\($0)" } ?? "none",
            spaceTitle: controller.activeSpace?.title ?? "none",
            frame: controller.window?.frame ?? .zero,
            isKey: controller.window?.isKeyWindow ?? false)
    }

    func spaceTitle(holding littleArcPage: any E2EPage, in page: any E2EPage) throws -> String? {
        try adapter.requireActive(token, "read where the page is")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let tab = try E2EAppAdapter.tabPage(littleArcPage).tab
        // The window lists the tabs of the Space on screen; the page must be one of them, and shown.
        guard controller.tabs.contains(where: { $0.tabID == tab.tabID }), controller.webView.isShowing(tab) else {
            return nil
        }
        return controller.activeSpace?.title
    }

    var openBrowsers: Int { adapter.openBrowserCount }

    func browserWindow(showing littleArcPage: any E2EPage) throws -> (state: E2EBrowserWindowState, offScreen: Bool)? {
        try adapter.requireActive(token, "read the window showing the page")
        let tab = try E2EAppAdapter.tabPage(littleArcPage).tab
        guard let controller = adapter.delegate.linkWindow(), controller.selectedTab?.tabID == tab.tabID,
            controller.webView.isShowing(tab), let window = controller.window
        else { return nil }
        let shown = controller.selectedTab.flatMap { controller.modelID(of: $0) }
        let state = E2EBrowserWindowState(
            tabs: controller.tabList.tabs.map { "\($0.id)=\($0.url?.absoluteString ?? "")" },
            shownTab: shown.map { "\($0)" } ?? "none",
            spaceTitle: controller.activeSpace?.title ?? "none",
            frame: window.frame,
            isKey: window.isKeyWindow)
        let offScreen = !window.isKeyWindow && !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        return (state, offScreen)
    }

    func littleArcDialog(in window: E2ELittleArcWindow) throws -> E2EPageDialog? {
        try adapter.requireActive(token, "read Little Arc's dialog")
        let panel = try adapter.littleArcPanel(window)
        guard let sheet = panel.dialogs.sheet else { return nil }
        let alert = sheet.alert
        return E2EPageDialog(
            title: alert.messageText, message: alert.informativeText, buttons: alert.buttons.map(\.title),
            field: sheet.field?.stringValue, isAttached: alert.window.sheetParent === panel.window)
    }

    func littleArcDialogIsOffScreen(in window: E2ELittleArcWindow) throws -> Bool {
        try adapter.requireActive(token, "read Little Arc's dialog")
        let panel = try adapter.littleArcPanel(window)
        guard let sheet = panel.dialogs.sheet else { throw E2EError("no dialog is up on Little Arc") }
        let frames = [panel.window.frame, sheet.alert.window.frame]
        return frames.allSatisfy { frame in !NSScreen.screens.contains { $0.frame.intersects(frame) } }
    }

    func answerLittleArcDialog(in window: E2ELittleArcWindow, accept: Bool) throws {
        try adapter.requireActive(token, "answer Little Arc's dialog")
        let panel = try adapter.littleArcPanel(window)
        guard let sheet = panel.dialogs.sheet else { throw E2EError("no dialog is up on Little Arc") }
        let buttons = sheet.alert.buttons
        guard let button = accept ? buttons.first : buttons.dropFirst().first else {
            throw E2EError("the dialog has no \(accept ? "OK" : "Cancel") button")
        }
        button.performClick(nil)
    }

    func littleArcPermissionPrompt(in window: E2ELittleArcWindow) throws -> E2EPermissionPrompt? {
        try adapter.requireActive(token, "read Little Arc's permission prompt")
        let panel = try adapter.littleArcPanel(window)
        guard let prompt = panel.prompts.visiblePrompt else { return nil }
        let token = token
        return E2EPermissionPrompt(
            kinds: Set(prompt.request.kinds.map(\.rawValue)), message: prompt.message, frame: prompt.frame
        ) { [weak adapter, weak prompt] allow in
            try adapter?.requireActive(token, allow ? "allow a permission" : "block a permission")
            (allow ? prompt?.allowButton : prompt?.blockButton)?.performClick(nil)
        }
    }

    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, inLittleArc window: E2ELittleArcWindow) throws
        -> String
    {
        try adapter.requireActive(token, "choose \(modifiers.shortcut(key)) in Little Arc")
        let panel = try adapter.littleArcPanel(window)
        guard let item = E2EAppAdapter.menuItem(key: key, modifiers: modifiers), let action = item.action else {
            throw E2EError("no menu item has the shortcut \(modifiers.shortcut(key))")
        }
        // As NSApp.target(forAction:) looks with Little Arc key and the browser window main: the key window's
        // responder chain and delegate, then the main window's chain, delegate and controller.
        var candidates: [AnyObject] = []
        for nsWindow in [panel.window as NSWindow, adapter.delegate.linkWindow()?.window].compactMap({ $0 }) {
            var responder: NSResponder? = nsWindow.firstResponder
            while let current = responder {
                candidates.append(current)
                responder = current.nextResponder
            }
            for extra in [nsWindow.delegate as AnyObject?, nsWindow.windowController] {
                if let extra, !candidates.contains(where: { $0 === extra }) { candidates.append(extra) }
            }
        }
        guard let target = candidates.first(where: { $0.responds(to: action) }) else { return "none" }
        let enabled: Bool
        if let validator = target as? NSMenuItemValidation {
            enabled = validator.validateMenuItem(item)
        } else if let validator = target as? NSUserInterfaceValidations {
            enabled = validator.validateUserInterfaceItem(item)
        } else {
            enabled = true
        }
        guard enabled else { return "disabled" }
        guard NSApp.sendAction(action, to: target, from: item) else {
            throw E2EError("\"\(item.title)\" could not be sent to \(type(of: target))")
        }
        return String(describing: type(of: target))
    }

    func littleArcAddress(in window: E2ELittleArcWindow) throws -> (isEditing: Bool, text: String) {
        try adapter.requireActive(token, "read Little Arc's address")
        let panel = try adapter.littleArcPanel(window)
        let text = panel.toolbar.host.currentEditor()?.string ?? panel.toolbar.host.stringValue
        return (panel.isEditingAddress, text)
    }

    func lastWindowClosedDecision() throws -> String {
        try adapter.requireActive(token, "read what closing the last window does")
        return "\(adapter.delegate.lastWindowClosed())"
    }

    func takeLittleArcClosedDecision() throws -> String {
        try adapter.requireActive(token, "read what closing the last Little Arc window did")
        defer { adapter.delegate.e2eLittleArcClosedDecision = nil }
        return adapter.delegate.e2eLittleArcClosedDecision.map { "\($0)" } ?? "none"
    }

    func hideDownloadsWindow() throws -> Bool {
        try adapter.requireActive(token, "hide the downloads window")
        let shown = NSApp.windows.filter { $0.isVisible && $0.windowController is DownloadsWindowController }
        for window in shown { window.orderOut(nil) }
        return !shown.isEmpty
    }

    func showDownloadsWindow() throws {
        try adapter.requireActive(token, "show the downloads window again")
        for window in NSApp.windows where window.windowController is DownloadsWindowController {
            window.orderFrontRegardless()
        }
    }

    func failNextLittleArcAdopt(in window: E2ELittleArcWindow) throws {
        try adapter.requireActive(token, "make Little Arc's move fail")
        try adapter.littleArcPanel(window).e2eFailsAdopt = true
    }
}
