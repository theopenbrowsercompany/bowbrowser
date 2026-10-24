import Foundation

/// The sidebar list: the active row lifted with a bold title, rows in a folder stepped in under its name, the Space
/// name between the Favorites and the tabs, and the list's fonts.
@MainActor
enum DesignSidebarTests {
    static let all: [any E2ETest] = [DesignSidebarTest()]
}

struct DesignSidebarTest: E2ETest {
    let name = "design.sidebar"
    let checks = ["design.selected_row", "design.folder_indent", "design.space_label", "design.fonts_sidebar"]

    /// Where a tab directly in a section puts its icon, from the sidebar's leading edge: where it was before rows in
    /// folders stepped in 22 points, which must not move it.
    static let topIconX = 43.0

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let fonts = run.app as? any E2EFontsApp else { throw E2EError("the app has no font hooks") }
        let page = try await DesignTests.openBrowsing(run)
        let read = try await run.step("read the sidebar", timeout: E2ETimeouts.step) {
            let look = try design.look(of: page)
            return (look.sidebar, look.favorites, try fonts.fonts(of: page))
        }
        let look = read.0
        run.check(
            "design.selected_row",
            passed: look.selectedRowBackground == DesignTests.activeLight
                && look.selectedRowText == DesignTests.textLight && look.selectedRowBold
                && look.selectedRowHeight == 34 && look.selectedRowCornerRadius == 9
                && look.selectedRowShadowOpacity > 0,
            "background=\(look.selectedRowBackground ?? "none") text=\(look.selectedRowText ?? "none")"
                + " bold=\(look.selectedRowBold) height=\(look.selectedRowHeight)"
                + " radius=\(look.selectedRowCornerRadius) shadow=\(look.selectedRowShadowOpacity)")
        run.check(
            "design.folder_indent",
            passed: look.childIconX - look.topIconX == 22 && look.topIconX == Self.topIconX
                && look.childRowHeight == 32,
            "top_icon=\(look.topIconX) child_icon=\(look.childIconX) child_row=\(look.childRowHeight)")
        let favorites = read.1.gridFrame
        run.check(
            "design.space_label",
            passed: look.spaceNameFrame.height > 0 && look.spaceNameFrame.minY >= favorites.maxY
                && look.spaceNameFrame.maxY <= look.firstTabRowFrame.minY,
            "favorites=\(favorites) name=\(look.spaceNameFrame) first_row=\(look.firstTabRowFrame)")

        let browsing = read.2
        let nunito = "Nunito Sans"
        run.check(
            "design.fonts_sidebar",
            passed: browsing.activeRow?.family == nunito && browsing.activeRow?.size == 13.5
                && browsing.activeRow?.name.contains("Bold") == true && browsing.spaceName?.family == nunito
                && browsing.spaceName?.size == 11 && browsing.spaceName?.name.contains("Bold") == true
                && browsing.folderRow?.family == nunito && browsing.folderRow?.size == 13.5
                && browsing.folderRow?.name.contains("SemiBold") == true,
            "active_row=\(String(describing: browsing.activeRow)) space_name=\(String(describing: browsing.spaceName))"
                + " folder_row=\(String(describing: browsing.folderRow))")
    }
}
