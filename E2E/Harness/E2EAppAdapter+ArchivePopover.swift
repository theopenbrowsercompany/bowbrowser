import AppKit
import BowCore

// The archive popover area of the adapter: the footer's archive button found by its identifier and clicked with
// performClick, the popover's rows and threshold menu read from the views the popover built, and their actions
// called the way a click or a menu choice calls them.

extension E2EAppAdapter {
    fileprivate func archiveButton(in page: any E2EPage) throws -> ArchiveButton {
        let sidebar = try Self.tabPage(page).controller.e2eSidebar
        guard
            let button = Self.views(in: sidebar.footer, ArchiveButton.self).first(where: {
                $0.identifier?.rawValue == ArchiveFooterButton.identifier
            })
        else { throw E2EError("the sidebar footer has no archive button") }
        return button
    }

    fileprivate func archivePopover(in page: any E2EPage) throws -> ArchivePopoverController {
        let button = try archiveButton(in: page)
        guard let popover = button.popover, popover.isShown,
            let content = popover.contentViewController as? ArchivePopoverController
        else { throw E2EError("the archive popover is not showing") }
        return content
    }
}

extension E2ETestApp: E2EArchivePopoverApp {
    func clickArchiveButton(in page: any E2EPage) throws {
        try adapter.requireActive(token, "click the archive button")
        try adapter.archiveButton(in: page).performClick(nil)
    }

    func archivePopoverIsShown(in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the archive popover")
        return try adapter.archiveButton(in: page).popover?.isShown == true
    }

    func archivePopoverRows(in page: any E2EPage) throws -> [E2EArchivePopoverRow] {
        try adapter.requireActive(token, "read the archive popover")
        return try adapter.archivePopover(in: page).rows.map {
            E2EArchivePopoverRow(item: $0.entryID.rawValue, title: $0.titleText, detail: $0.detailText)
        }
    }

    func archivePopoverShowsEmptyState(in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the archive popover")
        let content = try adapter.archivePopover(in: page)
        return E2EAppAdapter.views(in: content.view, NSTextField.self).contains {
            $0.identifier?.rawValue == ArchivePopoverController.emptyIdentifier && $0.stringValue == "No archived tabs"
        }
    }

    func clickArchivePopoverRow(_ item: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click an archived tab")
        guard let row = try adapter.archivePopover(in: page).rows.first(where: { $0.entryID.rawValue == item })
        else { throw E2EError("the archive popover has no row for \(item)") }
        row.performClick(nil)
    }

    func archiveThresholdMenu(in page: any E2EPage) throws -> (titles: [String], selected: String) {
        try adapter.requireActive(token, "read the threshold menu")
        guard let menu = try adapter.archivePopover(in: page).thresholdButton else {
            throw E2EError("the archive popover has no threshold menu")
        }
        return (menu.itemTitles, menu.titleOfSelectedItem ?? "")
    }

    func chooseArchiveThreshold(_ title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose a threshold")
        guard let menu = try adapter.archivePopover(in: page).thresholdButton, menu.itemTitles.contains(title)
        else { throw E2EError("the threshold menu has no \(title)") }
        menu.selectItem(withTitle: title)
        // What choosing the item in the open menu does: send the popup button's action.
        menu.sendAction(menu.action, to: menu.target)
    }

    func archiveSavedThreshold(besides page: any E2EPage) throws -> String {
        try adapter.requireActive(token, "read the saved threshold")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let profile = controller.store.graph.activeSpace?.profileID else {
            throw E2EError("the window shows no Space")
        }
        return adapter.archiveCenter.threshold(for: profile).title
    }

    func closeArchivePopover(in page: any E2EPage) {
        try? adapter.archiveButton(in: page).popover?.close()
    }
}
