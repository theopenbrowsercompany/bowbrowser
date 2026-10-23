import Foundation

// The collapse area of the adapter: E2ECollapseApp over View > Collapse All Folders and the window's
// CollapseFoldersFeature.

extension E2ETestApp: E2ECollapseApp {
    func chooseCollapseAllFolders(in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose View > Collapse All Folders")
        try adapter.chooseMenuItem(path: ["View", CollapseFoldersFeature.title], in: page)
    }

    func lastCollapsedCount(of page: any E2EPage) throws -> Int {
        try adapter.requireActive(token, "read the collapsed count")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(CollapseFoldersFeature.self) else {
            throw E2EError("the window has no collapse feature")
        }
        return feature.lastCollapsedCount
    }
}
