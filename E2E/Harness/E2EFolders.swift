import Foundation

/// A sheet attached to a window (a confirmation), as a test reads it: its text in order, its buttons' titles and
/// the title of the button Return presses, nil when none does.
struct E2ESheet: Equatable, CustomStringConvertible {
    var texts: [String]
    var buttons: [String]
    var returnButton: String?

    var description: String {
        "\(texts.joined(separator: " / ")) [\(buttons.joined(separator: ","))] return=\(returnButton ?? "none")"
    }
}

/// Sidebar folders as a test sees them: each row's context menu, double clicks, the rename field, the disclosure
/// triangle, dragging any row, and the confirmation sheet. Rows are numbered as `E2EZonesApp.sidebarOutline(of:)`
/// lists them, and each action goes through the control a person uses.
@MainActor
protocol E2EFoldersApp: E2EZonesApp, E2EStoreSeedApp, E2EStoreApp {
    /// The titles of the context menu row `row` of `page`'s window shows, a separator as "-"; empty for a row
    /// without one.
    func sidebarMenuTitles(row: Int, in page: any E2EPage) throws -> [String]
    /// Chooses the item titled `title` in the context menu of row `row`, as clicking it does. Throws when the menu
    /// has no such item.
    func chooseSidebarMenuItem(_ title: String, row: Int, in page: any E2EPage) throws
    /// Double clicks row `row`.
    func doubleClickSidebarRow(_ row: Int, in page: any E2EPage) throws
    /// The text of the name being edited in place in the sidebar of `page`'s window, nil while no name is.
    func sidebarRenameText(in page: any E2EPage) throws -> String?
    /// Types `text` over the selected text of the name being edited, then presses Return. Throws when no name is
    /// being edited.
    func typeSidebarRename(_ text: String, in page: any E2EPage) throws
    /// Clicks the disclosure triangle of folder row `row`, closing an open folder or opening a closed one. Throws
    /// for a row without a triangle.
    func clickSidebarDisclosure(row: Int, in page: any E2EPage) throws
    /// Drags the item of row `row` (a tab, folder or split) onto the outline as `E2EZonesApp.dragTab` does. Throws
    /// when the sidebar refuses the drop.
    func dragSidebarRow(_ row: Int, onRow target: Int?, childIndex: Int, in page: any E2EPage) throws
    /// The sheet attached to `page`'s window, nil when there is none.
    func sidebarSheet(in page: any E2EPage) throws -> E2ESheet?
    /// Clicks the button titled `title` on the sheet attached to `page`'s window.
    func clickSheetButton(_ title: String, in page: any E2EPage) throws
}
