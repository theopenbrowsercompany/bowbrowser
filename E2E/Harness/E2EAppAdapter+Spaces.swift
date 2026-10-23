import AppKit
import BowCore

// The Spaces area of the adapter: E2ESpacesApp over the window's sidebar store, the Space switcher accessories in
// its SidebarView (found by their views' identifiers), sheets on its window, and the sidebar's swipe handler.

extension E2EAppAdapter {
    func spaces(of page: any E2EPage) throws -> E2ESpacesState {
        let controller = try Self.tabPage(page).controller
        let graph = controller.store.graph
        let sidebar = controller.e2eSidebar
        let header = Self.views(in: sidebar.topSlot, NSTextField.self).first {
            $0.identifier?.rawValue == "space-name"
        }
        let footer = Self.views(in: sidebar.footer, NSButton.self).filter { $0.identifier?.rawValue == "space-icon" }
        // The outline's rows from the pinned section down, without the section headers: the Space's own tabs.
        let rows = try sidebarOutline(of: page)
        let tabs = rows.drop { $0 != "pinned" }.filter { !["pinned", "divider", "today"].contains($0) }
        let windows = NSApp.windows.filter { $0 is BrowserWindow && $0.isVisible }.count
        return E2ESpacesState(
            windows: windows,
            spaces: graph.spaces.map(\.title),
            active: graph.activeSpace?.title ?? "none",
            tabs: Array(tabs),
            header: header?.stringValue ?? "none",
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
        guard let handler = controller.e2eSidebar.swipeHandler else { throw E2EError("the sidebar has no swipe handler") }
        let context = controller.e2eSidebarFeature
        let sign: CGFloat = swipe == .towardsNext ? -1 : 1
        let total = sign * CGFloat(distance)
        handler.sidebarSwipe(SidebarSwipe(phase: .began, translation: total / 4), context: context)
        handler.sidebarSwipe(SidebarSwipe(phase: .changed, translation: total / 2), context: context)
        handler.sidebarSwipe(SidebarSwipe(phase: .ended, translation: total), context: context)
    }

    /// Every view of type `type` inside `root`, depth first, `root` included.
    private static func views<View: NSView>(in root: NSView, _ type: View.Type) -> [View] {
        ([root as? View].compactMap { $0 }) + root.subviews.flatMap { views(in: $0, type) }
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
