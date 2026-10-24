import AppKit
import BowCore

// The design area of the adapter: E2EDesignApp's window actions, captures, clock and fixture state. Each surface of
// `E2EDesignLook` is read in its own E2EAppAdapter+Design<Surface>.swift.

extension E2ETestApp: E2EDesignApp {
    func look(of page: any E2EPage) throws -> E2EDesignLook {
        try adapter.requireActive(token, "read the window's look")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let content = controller.window?.contentView else { throw E2EError("the window has closed") }
        content.layoutSubtreeIfNeeded()
        return E2EDesignLook(
            frame: try E2EAppAdapter.frameLook(of: controller),
            sidebar: E2EAppAdapter.sidebarLook(of: controller),
            favorites: E2EAppAdapter.favoritesLook(of: controller),
            footer: E2EAppAdapter.footerLook(of: controller),
            commandBar: E2EAppAdapter.commandBarLook(of: controller))
    }

    func resizeWindow(of page: any E2EPage, width: Double, height: Double) throws {
        try adapter.requireActive(token, "resize the window")
        guard let window = try E2EAppAdapter.tabPage(page).controller.window else {
            throw E2EError("the page has no window")
        }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: height)), display: true)
    }

    func setDarkAppearance(_ dark: Bool, of page: any E2EPage) throws {
        try adapter.requireActive(token, "change the window's appearance")
        try E2EAppAdapter.tabPage(page).controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    func forgetWindowLayout() throws {
        try adapter.requireActive(token, "forget the saved window layout")
        AppSettings.defaults.removeObject(forKey: AppSettings.windowLayoutKey)
    }

    func writeScreenshot(of page: any E2EPage, to url: URL) async throws {
        try adapter.requireActive(token, "take a screenshot")
        let png: Data
        if page.contentView != nil {
            png = try await E2EScreenshot.png(page)
        } else {
            guard let window = try E2EAppAdapter.tabPage(page).controller.window else {
                throw E2EError("the page has no window")
            }
            png = try E2EScreenshot.png(window: window)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    func capture(of page: any E2EPage, _ region: E2EDesignRegion) async throws -> Data {
        try adapter.requireActive(token, "take a design capture")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let window = controller.window, let root = window.contentView?.superview ?? window.contentView else {
            throw E2EError("the page has no window")
        }
        E2EAppAdapter.parkPointer(off: controller.e2eSidebar, in: window)
        let caret = window.firstResponder as? NSTextView
        let caretColor = caret?.insertionPointColor
        caret?.insertionPointColor = .clear
        defer { if let caret, let caretColor { caret.insertionPointColor = caretColor } }
        root.layoutSubtreeIfNeeded()
        switch region {
        case .sidebar:
            let sidebar = controller.e2eSidebar
            guard sidebar.window === window, !sidebar.isHiddenOrHasHiddenAncestor else {
                throw E2EError("the window shows no sidebar")
            }
            let frame = root.convert(sidebar.bounds, from: sidebar)
            // The sidebar's column from the window's top edge (window buttons included) to its bottom edge.
            let column = NSRect(x: frame.minX, y: root.bounds.minY, width: frame.width, height: root.bounds.height)
            return try E2EScreenshot.png(window: window, crop: column)
        case .window:
            if let shown = try adapter.shownPage(besides: page, token: token), shown.contentView?.window === window {
                return try await E2EScreenshot.png(shown)
            }
            return try E2EScreenshot.png(window: window)
        }
    }

    func useClock(_ date: Date?) throws {
        try adapter.requireActive(token, "fix the clock")
        EmptySpaceFeature.e2eUseClock(date.map { ManualTimeSource($0) })
    }

    func fixtureState(of page: any E2EPage) throws -> E2EDesignFixtureState {
        try adapter.requireActive(token, "read the fixture's state")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let graph = controller.store.graph
        func describe(_ id: SidebarItemID) -> String {
            guard let item = graph[id] else { return "?" }
            switch item.data {
            case .tab(let tab): return item.title ?? tab.savedTitle
            case .folder:
                let children = graph.children(of: id).map { describe($0.id) }.joined(separator: ",")
                return "\(item.title ?? "")[\(children)]"
            default: return item.title ?? "?"
            }
        }
        let spaces = graph.spaces.map { space -> E2EDesignFixtureState.Space in
            E2EDesignFixtureState.Space(
                name: space.title, icon: space.icon?.kind == .emoji ? space.icon?.value : nil,
                theme: space.theme.map { $0.primaryColor.hex },
                pinned: graph.children(of: space.pinnedContainerID).map { describe($0.id) },
                today: graph.children(of: space.unpinnedContainerID).map { describe($0.id) })
        }
        let activeItem = controller.tabList.activeID.flatMap { controller.sidebarItemID(for: $0) }
        let hasIcon = activeItem.flatMap { controller.feature(SidebarFeature.self)?.favicon(for: $0) } != nil
        return E2EDesignFixtureState(
            spaces: spaces, favorites: graph.activeFavoriteIDs.map(describe),
            activeTab: activeItem.map(describe), activeTabHasIcon: hasIcon)
    }
}

extension E2EAppAdapter {
    /// Goes back to the real clock after a test that fixed it.
    func resetDesignClock() {
        EmptySpaceFeature.e2eUseClock(nil)
    }

    /// Tells every view in `sidebar` that tracks the pointer that it left, so no row, tile or button shows a hover
    /// left from a synthetic event; the real pointer never reaches the off-screen window.
    static func parkPointer(off sidebar: NSView, in window: NSWindow) {
        for view in views(in: sidebar, NSView.self) {
            for area in view.trackingAreas where area.options.contains(.mouseEnteredAndExited) {
                guard let owner = area.owner as? NSResponder,
                    let event = NSEvent.enterExitEvent(
                        with: .mouseExited, location: NSPoint(x: -1, y: -1), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                        userData: nil)
                else { continue }
                owner.mouseExited(with: event)
            }
        }
    }

    /// `color` as `#RRGGBB` in sRGB, resolved in `appearance`.
    static func designHex(_ color: NSColor?, in appearance: NSAppearance) -> String? {
        guard let color else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let rgb = resolved else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}
