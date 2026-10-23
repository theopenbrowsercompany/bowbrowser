import AppKit

// The menu area of the adapter: E2EMenuApp, and the menu lookup and dispatch every shortcut the harness presses goes
// through (E2EApp.press, E2ESidebarApp.chooseMenuItem(commandKey:) and the find bar).

extension E2EAppAdapter {
    /// The first main menu item, depth first, whose shortcut is `key` with exactly `modifiers`.
    static func menuItem(key: String, modifiers: E2EKeyModifiers) -> NSMenuItem? {
        let wanted = normalized(key: key, modifiers: modifiers)
        return shortcutItems(in: NSApp.mainMenu).first { shortcut(of: $0) == wanted }
    }

    /// Every main menu item whose shortcut a key press can reach, depth first. A hidden item is skipped with its
    /// submenu, as AppKit skips them for key presses, unless it allows its key equivalent while hidden (its submenu
    /// is still skipped).
    private static func shortcutItems(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { item -> [NSMenuItem] in
            let reachable = !item.isHidden || item.allowsKeyEquivalentWhenHidden
            let own = reachable && !item.keyEquivalent.isEmpty ? [item] : []
            return own + (item.isHidden ? [] : shortcutItems(in: item.submenu))
        }
    }

    private struct Shortcut: Equatable {
        var key: String
        var modifiers: E2EKeyModifiers
    }

    private static func shortcut(of item: NSMenuItem) -> Shortcut {
        normalized(key: item.keyEquivalent, modifiers: modifiers(of: item.keyEquivalentModifierMask))
    }

    /// An uppercase letter means Shift with that letter, as AppKit reads a key equivalent. Symbols do not fold.
    private static func normalized(key: String, modifiers: E2EKeyModifiers) -> Shortcut {
        let lower = key.lowercased()
        guard lower != key else { return Shortcut(key: key, modifiers: modifiers) }
        return Shortcut(key: lower, modifiers: modifiers.union(.shift))
    }

    private static func modifiers(of mask: NSEvent.ModifierFlags) -> E2EKeyModifiers {
        var modifiers: E2EKeyModifiers = []
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.shift) { modifiers.insert(.shift) }
        if mask.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// App and window chrome actions a test may not take through a menu, with what they would do: they would quit
    /// the run, or move the off-screen window or the app in front of the person at the screen. Only `app.quit`
    /// quits, through the runner.
    private static let refusedActions: [Selector: String] = [
        #selector(NSApplication.terminate(_:)): "it quits the app (only app.quit quits, through the runner)",
        #selector(NSApplication.hide(_:)): "it hides the app",
        #selector(NSApplication.hideOtherApplications(_:)): "it hides other apps",
        #selector(NSApplication.unhideAllApplications(_:)): "it shows other apps",
        #selector(NSApplication.arrangeInFront(_:)): "it brings every window to the front",
        #selector(NSApplication.miniaturizeAll(_:)): "it minimizes every window",
        #selector(NSApplication.orderFrontStandardAboutPanel(_:)): "it opens the About panel",
        #selector(NSWindow.performMiniaturize(_:)): "it minimizes the window",
        #selector(NSWindow.miniaturize(_:)): "it minimizes the window",
        #selector(NSWindow.performZoom(_:)): "it zooms the window",
        #selector(NSWindow.zoom(_:)): "it zooms the window",
        #selector(NSWindow.toggleFullScreen(_:)): "it moves the window to full screen",
    ]

    private enum Route {
        case refused(String)
        /// The item names a target of its own that is not in the test window.
        case outside(AnyObject)
        case unhandled
        case handler(AnyObject)
    }

    /// Where `item` goes in `window`, as AppKit sends a key press's menu action when the window is key, but asking
    /// only the window: its responder chain from the first responder, then its delegate and its controller. The
    /// application and its delegate are left out on purpose, so an app level fallback (one acting on the key window,
    /// which an e2e window never is) cannot stand in for a window command.
    private static func route(of item: NSMenuItem, action: Selector, in window: NSWindow) -> Route {
        if let reason = refusedActions[action] { return .refused(reason) }
        var candidates: [AnyObject] = []
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            candidates.append(current)
            responder = current.nextResponder
        }
        for extra in [window.delegate as AnyObject?, window.windowController] {
            if let extra, !candidates.contains(where: { $0 === extra }) { candidates.append(extra) }
        }
        if let target = item.target {
            guard candidates.contains(where: { $0 === target }) else { return .outside(target) }
            return target.responds(to: action) ? .handler(target) : .unhandled
        }
        return candidates.first { $0.responds(to: action) }.map { .handler($0) } ?? .unhandled
    }

    private static func window(of page: any E2EPage) throws -> NSWindow {
        guard let window = try tabPage(page).controller.window else { throw E2EError("the page has no window") }
        return window
    }

    /// Finds the menu item with the shortcut and sends its action to the object `route(of:action:in:)` picks in the
    /// page's window, after that object validates the item. The e2e window never becomes key, so the window is
    /// named here instead of AppKit finding the key window.
    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, in page: any E2EPage) throws {
        let window = try Self.window(of: page)
        let shortcut = modifiers.shortcut(key)
        guard let item = Self.menuItem(key: key, modifiers: modifiers), let action = item.action else {
            throw E2EError("no menu item has the shortcut \(shortcut)")
        }
        let target: AnyObject
        switch Self.route(of: item, action: action, in: window) {
        case .refused(let reason):
            throw E2EError("refused to choose \"\(item.title)\" (\(shortcut)) in a test: \(reason)")
        case .outside(let other):
            throw E2EError(
                "\"\(item.title)\" (\(shortcut)) targets \(type(of: other)), which is not in the test window")
        case .unhandled:
            throw E2EError(
                "nothing in the test window handles \"\(item.title)\" (\(shortcut)); the app and its delegate are not asked"
            )
        case .handler(let handler):
            target = handler
        }
        // AppKit asks validateMenuItem(_:), or validateUserInterfaceItem(_:) when the target has only that.
        let enabled: Bool
        if let validator = target as? NSMenuItemValidation {
            enabled = validator.validateMenuItem(item)
        } else if let validator = target as? NSUserInterfaceValidations {
            enabled = validator.validateUserInterfaceItem(item)
        } else {
            enabled = true
        }
        if !enabled {
            throw E2EError("\"\(item.title)\" (\(shortcut)) is disabled")
        }
        // Sent straight to the chosen target, so it only fails when that target stops responding.
        guard NSApp.sendAction(action, to: target, from: item) else {
            throw E2EError("\"\(item.title)\" (\(shortcut)) could not be sent to \(type(of: target))")
        }
    }

    func menuRoutes(in page: any E2EPage) throws -> [E2EMenuRoute] {
        let window = try Self.window(of: page)
        return Self.shortcutItems(in: NSApp.mainMenu).map { item in
            let shortcut = Self.shortcut(of: item)
            let handler: String
            switch item.action.map({ Self.route(of: item, action: $0, in: window) }) ?? .unhandled {
            case .refused: handler = "refused"
            case .outside: handler = "outside"
            case .unhandled: handler = "none"
            case .handler(let target): handler = String(describing: type(of: target))
            }
            return E2EMenuRoute(
                shortcut: shortcut.modifiers.shortcut(shortcut.key), title: item.title, handler: handler)
        }
    }
}

extension E2ETestApp: E2EMenuApp {
    func menuItemTitle(key: String, modifiers: E2EKeyModifiers) -> String? {
        E2EAppAdapter.menuItem(key: key, modifiers: modifiers)?.title
    }

    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose the menu item for \(modifiers.shortcut(key))")
        try adapter.chooseMenuItem(key: key, modifiers: modifiers, in: page)
    }

    func menuRoutes(in page: any E2EPage) throws -> [E2EMenuRoute] {
        try adapter.requireActive(token, "read the menu routes")
        return try adapter.menuRoutes(in: page)
    }
}
