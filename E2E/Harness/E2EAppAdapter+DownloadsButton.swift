import AppKit

// The downloads button of the sidebar footer in the adapter: found by its identifier and clicked with performClick,
// as a person's click would; the downloads window is the one `downloadsList()` opened off screen.

extension E2EAppAdapter {
    private func downloadsButton(in page: any E2EPage) throws -> NSButton {
        let sidebar = try Self.tabPage(page).controller.e2eSidebar
        guard
            let button = Self.views(in: sidebar.footer, NSButton.self).first(where: {
                $0.identifier?.rawValue == DownloadsFooterButton.identifier
            })
        else { throw E2EError("the sidebar footer has no downloads button") }
        return button
    }

    func clickDownloadsButton(in page: any E2EPage) throws {
        try downloadsButton(in: page).performClick(nil)
    }

    func downloadsButtonShowsActivity(in page: any E2EPage) throws -> Bool {
        try downloadsButton(in: page).accessibilityValue() != nil
    }

    func hideDownloadsWindow() async throws {
        try await downloadsList().window?.orderOut(nil)
    }

    func visibleDownloadsWindowCount() -> Int {
        NSApp.windows.filter { $0.isVisible && $0.windowController is DownloadsWindowController }.count
    }
}

extension E2ETestApp: E2EDownloadsButtonApp {
    func clickDownloadsButton(in page: any E2EPage) throws {
        try adapter.requireActive(token, "click the downloads button")
        try adapter.clickDownloadsButton(in: page)
    }

    func downloadsButtonShowsActivity(in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the downloads button")
        return try adapter.downloadsButtonShowsActivity(in: page)
    }

    func hideDownloadsWindow() async throws {
        try adapter.requireActive(token, "hide the downloads window")
        try await adapter.hideDownloadsWindow()
    }

    func visibleDownloadsWindowCount() -> Int {
        adapter.visibleDownloadsWindowCount()
    }
}
