import Foundation

/// Page context menus as a test sees them: no menu is put on screen, the test chooses an item by its title instead,
/// and every menu a page asked for is recorded with what the app was told. E2E/Harness/E2EAppAdapter+ContextMenu.swift
/// implements it; every action is refused once the test has ended.
@MainActor
protocol E2EContextMenuApp: E2EApp {
    /// From now on, each context menu a page asks for is answered by choosing its enabled item titled `title`, or
    /// nothing when `title` is nil or no such item is shown, and recorded.
    func chooseContextMenuItem(_ title: String?) throws
    /// The menus pages asked for since the test's first `chooseContextMenuItem`, oldest first.
    func contextMenus() throws -> [E2EContextMenu]
    /// How many times `page`'s tab asked to show DevTools, and the point the last request inspected (nil for none).
    /// An e2e run records the requests instead of opening DevTools: the engine version Bow uses opens it only as a
    /// window of its own, which would show on screen and activate the app.
    func devToolsRequests(of page: any E2EPage) throws -> (count: Int, point: CGPoint?)
    /// What the person could see of the app: its visible windows (off-screen test windows included), whether it is
    /// active, and whether it shows in the Dock.
    var screenState: String { get }
}

/// One context menu a page asked for: what the request carried and the items the app showed.
struct E2EContextMenu {
    var linkURL: URL?
    var items: [String]
    var chosen: String?
}

extension E2EPage {
    /// Right clicks the center of the first element matching `selector`, which asks the page for a context menu.
    /// Like `click(_:button:modifiers:)` it is confirmed: a press or `contextmenu` event the page never saw (Chromium
    /// drops input while a page's frame updates are deferred, yet the DevTools call succeeds) is sent again and logged
    /// as `E2E right click <selector>: ...`, and once the page saw `contextmenu` nothing is sent again, so the page
    /// asks for one menu.
    func rightClick(_ selector: String) async throws {
        let target = try await pressTarget(selector, verb: "right click")
        // The right button's held bit is 2.
        try await confirmedPress(
            at: target, verb: "right click", button: "right", heldBit: 2, modifiers: [],
            released: (name: "contextmenu", events: ["contextmenu"]))
    }
}
