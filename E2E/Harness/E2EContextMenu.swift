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
    func rightClick(_ selector: String) async throws {
        try await emulateFocus()
        let center = try await evaluate(
            """
            (() => {
              const element = document.querySelector(\(Self.jsString(selector)));
              if (!element) return 'no element matches';
              element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              const rect = element.getBoundingClientRect();
              if (rect.width === 0 || rect.height === 0) return 'the element has no size';
              return [rect.left + rect.width / 2, rect.top + rect.height / 2];
            })()
            """
        )
        guard let point = center as? [Double], point.count == 2 else {
            throw E2EError("cannot right click \(selector): \(center as? String ?? "no position")")
        }
        // `buttons` is the buttons held after the event: the right one (2) while pressed, none once released.
        for (type, buttons) in [("mousePressed", 2), ("mouseReleased", 0)] {
            _ = try await devTools(
                "Input.dispatchMouseEvent",
                ["type": type, "x": point[0], "y": point[1], "button": "right", "buttons": buttons, "clickCount": 1]
            )
        }
    }
}
