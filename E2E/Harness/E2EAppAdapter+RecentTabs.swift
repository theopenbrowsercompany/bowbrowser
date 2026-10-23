import AppKit
import BowCore

// The recent tabs area of the adapter: E2ERecentTabsApp over the window's RecentTabsFeature.

extension E2ETestApp: E2ERecentTabsApp {
    func clickTabRow(_ item: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click a tab row")
        let sidebar = try E2EAppAdapter.tabPage(page).controller.e2eSidebar
        guard let row = sidebar.row(for: SidebarItemID(item)) else { throw E2EError("tab \(item) has no sidebar row") }
        sidebar.clickRow(row)
    }

    func pressRecentTabs(shift: Bool, in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "press Ctrl+Tab")
        let modifiers: KeyModifiers = shift ? [.control, .shift] : .control
        return try Self.sendKey(keyCode: KeyChord.tabKeyCode, characters: "\t", modifiers, to: page)
    }

    func pressEscapeBeforePage(in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "press Escape")
        return try Self.sendKey(keyCode: KeyChord.escapeKeyCode, characters: "\u{1b}", [], to: page)
    }

    func releaseControl(in page: any E2EPage) throws {
        try adapter.requireActive(token, "release Ctrl")
        let window = try E2EAppAdapter.tabPage(page).controller.window
        // The Control key (kVK_Control) going up leaves no modifier held. Sent through the application, which
        // runs the local event monitors, as the system's own event does.
        guard
            let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)
        else { throw E2EError("cannot make a flags changed event") }
        NSApp.sendEvent(event)
    }

    func recentTabs(of page: any E2EPage) throws -> E2ERecentTabsState {
        try adapter.requireActive(token, "read the recent tabs overlay")
        let feature = try Self.recentFeature(of: page)
        return E2ERecentTabsState(
            isShown: feature.isOpen && !feature.panel.isHidden,
            // Read from the rows the panel draws, so a row the view lost shows up as missing.
            rows: feature.panel.rows.map { view in
                view.row.space.map { "\(view.row.title) @ \($0.name)" } ?? view.row.title
            },
            highlighted: feature.panel.rows.firstIndex { $0.isSelected },
            monitoring: feature.isMonitoring)
    }

    private static func sendKey(keyCode: Int, characters: String, _ modifiers: KeyModifiers, to page: any E2EPage)
        throws
        -> Bool
    {
        let page = try E2EAppAdapter.tabPage(page)
        let event = EngineKeyEvent(
            kind: .keyDown, keyCode: keyCode, characters: characters, charactersIgnoringModifiers: characters,
            modifiers: modifiers)
        return page.controller.tab(page.tab, handleKeyBeforePage: event)
    }

    private static func recentFeature(of page: any E2EPage) throws -> RecentTabsFeature {
        guard let feature = try E2EAppAdapter.tabPage(page).controller.feature(RecentTabsFeature.self) else {
            throw E2EError("the window has no recent tabs feature")
        }
        return feature
    }
}
