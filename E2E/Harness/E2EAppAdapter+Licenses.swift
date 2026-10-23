import AppKit

// The licenses area of the adapter: choosing About Bow through the app menu, which targets the app and not a window.

/// The About Bow menu item, chosen through the app's menu.
@MainActor
protocol E2ELicensesApp: E2EApp {
    /// Chooses Bow > About Bow in the window `page` is in, with the About panel replaced by a recorder so nothing
    /// shows on screen. Returns the options the panel was asked to show, nil when the item did not ask for a panel.
    func chooseAbout(in page: any E2EPage) throws -> [NSApplication.AboutPanelOptionKey: Any]?
}

extension E2ETestApp: E2ELicensesApp {
    func chooseAbout(in page: any E2EPage) throws -> [NSApplication.AboutPanelOptionKey: Any]? {
        try adapter.requireActive(token, "choose Bow > About Bow")
        let original = Licenses.presentAboutPanel
        defer { Licenses.presentAboutPanel = original }
        var shown: [NSApplication.AboutPanelOptionKey: Any]?
        Licenses.presentAboutPanel = { shown = $0 }
        try adapter.chooseMenuItem(path: ["Bow", "About Bow"], in: page, allowAppTarget: true)
        return shown
    }
}
