import AppKit
import BowCore

// The Spaces area of the adapter: E2ESpacesApp over the window's sidebar store, the Space name in its SidebarView's
// outline and the Space switcher in its footer (found by their views' identifiers), sheets on its window, and the
// sidebar's swipe handler.

extension E2EAppAdapter {
    func spaces(of page: any E2EPage) throws -> E2ESpacesState {
        let controller = try Self.tabPage(page).controller
        let graph = controller.store.graph
        let sidebar = controller.e2eSidebar
        let header = Self.views(in: sidebar.outlineView, NSTextField.self).first {
            $0.identifier?.rawValue == "space-name"
        }
        let footer = Self.views(in: sidebar.footer, NSButton.self).filter { $0.identifier?.rawValue == "space-icon" }
        // The outline's rows from the pinned section down, without the section headers: the Space's own tabs.
        let rows = try sidebarOutline(of: page)
        let tabs = rows.drop { $0 != "pinned" }.filter { !["pinned", "divider", "today"].contains($0) }
        // Windows showing this window's sidebar: a switch that opened another window for a Space would show here.
        // Windows other tests or the app keep open on other sidebars are not this test's.
        let windows = NSApp.windows.filter { window in
            guard window.isVisible, let other = window.windowController as? BrowserWindowController else {
                return false
            }
            return other.store === controller.store
        }.count
        return E2ESpacesState(
            windows: windows,
            spaces: graph.spaces.map(\.title),
            active: graph.activeSpace?.title ?? "none",
            tabs: Array(tabs),
            // The header shows the name uppercase; its tooltip keeps it as typed.
            header: header?.toolTip ?? "none",
            footer: footer.map {
                ($0.accessibilityLabel() ?? "?") + ($0.accessibilityValue() as? String == "on screen" ? "*" : "")
            }
        )
    }

    func clickNewSpaceButton(in page: any E2EPage) throws {
        let sidebar = try Self.tabPage(page).controller.e2eSidebar
        guard
            let button = Self.views(in: sidebar.footer, NSButton.self).first(where: {
                $0.identifier?.rawValue == "new-space"
            })
        else { throw E2EError("the sidebar has no New Space button") }
        button.performClick(nil)
    }

    func sheetMessage(in page: any E2EPage) throws -> String? {
        guard let sheet = try Self.tabPage(page).controller.window?.attachedSheet, let content = sheet.contentView
        else { return nil }
        let labels = Self.views(in: content, NSTextField.self).filter { !$0.isEditable && !$0.stringValue.isEmpty }
        return labels.map(\.stringValue).joined(separator: " | ")
    }

    func answerSheet(_ title: String, text: String?, in page: any E2EPage) throws {
        guard let sheet = try Self.tabPage(page).controller.window?.attachedSheet, let content = sheet.contentView
        else { throw E2EError("no sheet is up") }
        if let text {
            guard let field = Self.views(in: content, NSTextField.self).first(where: \.isEditable) else {
                throw E2EError("the sheet has no text field")
            }
            field.stringValue = text
        }
        guard let button = Self.views(in: content, NSButton.self).first(where: { $0.title == title }) else {
            throw E2EError("the sheet has no button \"\(title)\"")
        }
        button.performClick(nil)
    }

    func swipeSidebar(_ swipe: E2ESwipe, distance: Double, in page: any E2EPage) throws {
        let controller = try Self.tabPage(page).controller
        guard let handler = controller.e2eSidebar.swipeHandler else {
            throw E2EError("the sidebar has no swipe handler")
        }
        let context = controller.e2eSidebarFeature
        let sign: CGFloat = swipe == .towardsNext ? -1 : 1
        let total = sign * CGFloat(distance)
        handler.sidebarSwipe(SidebarSwipe(phase: .began, translation: total / 4), context: context)
        handler.sidebarSwipe(SidebarSwipe(phase: .changed, translation: total / 2), context: context)
        handler.sidebarSwipe(SidebarSwipe(phase: .ended, translation: total), context: context)
    }
}

extension E2ETestApp: E2ESpacesApp {
    func spaces(of page: any E2EPage) throws -> E2ESpacesState {
        try adapter.spaces(of: page)
    }

    func clickNewSpaceButton(in page: any E2EPage) throws {
        try adapter.requireActive(token, "click the New Space button")
        try adapter.clickNewSpaceButton(in: page)
    }

    func chooseSpacesMenuItem(_ title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose View > Spaces > \(title)")
        try adapter.chooseMenuItem(path: ["View", "Spaces", title], in: page)
    }

    func sheetMessage(in page: any E2EPage) throws -> String? {
        try adapter.sheetMessage(in: page)
    }

    func answerSheet(_ button: String, text: String?, in page: any E2EPage) throws {
        try adapter.requireActive(token, "answer a sheet with \(button)")
        try adapter.answerSheet(button, text: text, in: page)
    }

    func swipeSidebar(_ swipe: E2ESwipe, distance: Double, in page: any E2EPage) throws {
        try adapter.requireActive(token, "swipe the sidebar \(swipe)")
        try adapter.swipeSidebar(swipe, distance: distance, in: page)
    }
}

// Space themes: the Space menu comes from the Space name view's own `menu(for:)` with a synthetic right click, so
// it never pops up, and its items run the way a click on them does.

extension E2EAppAdapter {
    func spaceTheme(of page: any E2EPage) throws -> E2ESpaceTheme {
        let controller = try Self.tabPage(page).controller
        guard let window = controller.window else { throw E2EError("the window has closed") }
        let graph = controller.store.graph
        let appearance = window.effectiveAppearance
        return E2ESpaceTheme(
            icons: graph.spaces.map { $0.icon?.value ?? "-" },
            themes: graph.spaces.map { $0.theme?.primaryColor.hex ?? "default" },
            activeTheme: graph.activeTheme.primaryColor.hex,
            background: Self.e2eHex(window.backgroundColor, in: appearance) ?? "none",
            dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            animating: controller.feature(SpaceThemeFeature.self)?.isAnimating ?? false,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func sidebarDrawnColor(of page: any E2EPage) throws -> String {
        let controller = try Self.tabPage(page).controller
        guard let window = controller.window, let content = window.contentView else {
            throw E2EError("the window has closed")
        }
        content.layoutSubtreeIfNeeded()
        // The frame view above the content view draws the window's background.
        let root = content.superview ?? content
        let footer = controller.e2eSidebar.footer
        let footerFrame = root.convert(footer.bounds, from: footer)
        // Just above the footer, in the empty end of the outline.
        let point = NSPoint(x: footerFrame.midX, y: root.isFlipped ? footerFrame.minY - 24 : footerFrame.maxY + 24)
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw E2EError("cannot make a bitmap of the window")
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / max(root.bounds.width, 1)
        let row = root.isFlipped ? point.y : root.bounds.height - point.y
        guard let color = bitmap.colorAt(x: Int(point.x * scale), y: Int(row * scale)) else {
            throw E2EError("no pixel at \(point)")
        }
        // The window's background reaches the screen's pixels as its sRGB values, unmatched to the screen's profile,
        // so the bitmap's own values are what was drawn; converting them would apply the profile a second time.
        let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    func spaceMenuTitles(in page: any E2EPage) throws -> [String] {
        func title(_ item: NSMenuItem) -> String {
            item.title + (item.state == .on ? "*" : "") + (item.isEnabled ? "" : "!")
        }
        return try spaceMenu(in: page).items.flatMap { item -> [String] in
            guard !item.isSeparatorItem else { return ["-"] }
            let children = item.submenu?.items.map { "\(item.title)/\($0.isSeparatorItem ? "-" : title($0))" } ?? []
            return [title(item)] + children
        }
    }

    func chooseSpaceMenuItem(_ path: [String], in page: any E2EPage) throws {
        var items = try spaceMenu(in: page).items
        var chosen: NSMenuItem?
        for title in path {
            guard let item = items.first(where: { $0.title == title }) else {
                throw E2EError("the Space menu has no item \"\(path.joined(separator: "/"))\": \(items.map(\.title))")
            }
            chosen = item
            items = item.submenu?.items ?? []
        }
        guard let item = chosen, item.isEnabled, let action = item.action else {
            throw E2EError("the Space menu's \"\(path.joined(separator: "/"))\" is disabled")
        }
        guard NSApp.sendAction(action, to: item.target, from: item) else {
            throw E2EError("the Space menu's \"\(path.joined(separator: "/"))\" did nothing")
        }
    }

    /// The Space menu, as the Space name view builds it for a right click.
    private func spaceMenu(in page: any E2EPage) throws -> NSMenu {
        let controller = try Self.tabPage(page).controller
        guard let window = controller.window,
            let nameView = Self.views(in: controller.e2eSidebar.outlineView, SpaceNameView.self).first
        else { throw E2EError("the sidebar shows no Space name") }
        guard
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: nameView.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1),
            let menu = nameView.menu(for: event)
        else { throw E2EError("the Space name has no menu") }
        return menu
    }

    /// `color` as `#RRGGBB` in sRGB, resolved in `appearance`.
    static func e2eHex(_ color: NSColor?, in appearance: NSAppearance) -> String? {
        guard let color else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let rgb = resolved else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}

extension E2ETestApp: E2ESpaceThemeApp {
    func spaceTheme(of page: any E2EPage) throws -> E2ESpaceTheme {
        try adapter.spaceTheme(of: page)
    }

    func sidebarDrawnColor(of page: any E2EPage) throws -> String {
        try adapter.requireActive(token, "read the sidebar's drawn color")
        return try adapter.sidebarDrawnColor(of: page)
    }

    func spaceMenuTitles(in page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the Space menu")
        return try adapter.spaceMenuTitles(in: page)
    }

    func chooseSpaceMenuItem(_ path: [String], in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose \(path.joined(separator: " > ")) in the Space menu")
        try adapter.chooseSpaceMenuItem(path, in: page)
    }
}
