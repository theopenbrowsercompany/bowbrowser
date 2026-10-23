import AppKit
import BowCore

// The import area of the adapter: E2EImportApp over the wizard sheet (ArcImportWizard) on the window and the window's
// sidebar store. The sheet is driven the way a person does: through File > Import from Arc… and by pressing its
// buttons; the file picker is answered by ArcImportFeature's seam, so no open panel ever shows.

extension E2EAppAdapter {
    private var importService: ArcImportFeature { delegate.appFeatures.require(ArcImportFeature.self) }

    private static func wizardSheet(in page: any E2EPage) throws -> NSWindow? {
        guard let sheet = try tabPage(page).controller.window?.attachedSheet,
            sheet.contentView?.accessibilityIdentifier().hasPrefix("arcImport.") == true
        else { return nil }
        return sheet
    }

    func useImportFile(_ name: String?) throws {
        // Each test counts its own requests.
        importService.e2eFileRequests = 0
        guard let name else {
            importService.e2eChooseFile = nil
            return
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/import/\(name)"),
            FileManager.default.fileExists(atPath: url.path)
        else { throw E2EError("the app bundle has no Fixtures/import/\(name)") }
        importService.e2eChooseFile = { url }
    }

    func importFileRequests() -> Int { importService.e2eFileRequests }

    private func importMenuItem() throws -> NSMenuItem {
        guard
            let item = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?.items
                .first(where: { $0.title == ImportMenuFeature.title })
        else { throw E2EError("File has no \(ImportMenuFeature.title) item") }
        return item
    }

    func importMenuItemEnabled(in page: any E2EPage) throws -> Bool {
        let controller = try Self.tabPage(page).controller
        guard let feature = controller.feature(ImportMenuFeature.self) else {
            throw E2EError("the window has no import feature")
        }
        return feature.validateMenuItem(try importMenuItem())
    }

    func importWizardState(in page: any E2EPage) throws -> E2EImportWizardState? {
        guard let sheet = try Self.wizardSheet(in: page), let content = sheet.contentView else { return nil }
        let step = content.accessibilityIdentifier().dropFirst("arcImport.".count)
        let labels = Self.views(in: content, NSTextField.self).filter { !$0.isEditable && !$0.stringValue.isEmpty }
        // The outline's own cell labels are the tree, not text.
        let outline = Self.views(in: content, NSOutlineView.self).first
        let outsideTree = labels.filter { label in outline.map { !label.isDescendant(of: $0) } ?? true }
        let buttons = Self.views(in: content, NSButton.self).filter {
            ($0 as? WizardButton)?.isCheckbox == false
        }
        let boxes = Self.views(in: content, NSButton.self).filter { ($0 as? WizardButton)?.isCheckbox == true }
        var tree: [String] = []
        if let outline {
            for row in 0..<outline.numberOfRows {
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
                tree.append("\(outline.level(forRow: row)):\(cell?.textField?.stringValue ?? "?")")
            }
        }
        return E2EImportWizardState(
            step: String(step), texts: outsideTree.map(\.stringValue),
            buttons: buttons.map { $0.isEnabled ? $0.title : "\($0.title) (off)" },
            checkboxes: boxes.map { "\($0.title)=\($0.state == .on ? "on" : "off")" },
            mode: Self.views(in: content, NSPopUpButton.self).first?.titleOfSelectedItem, tree: tree)
    }

    func pressImportButton(_ title: String, in page: any E2EPage) throws {
        guard let content = try Self.wizardSheet(in: page)?.contentView else { throw E2EError("no wizard sheet is up") }
        guard let button = Self.views(in: content, NSButton.self).first(where: { $0.title == title && $0.isEnabled })
        else { throw E2EError("the wizard has no enabled \"\(title)\" button") }
        button.performClick(nil)
    }

    func setImportCheckbox(_ title: String, on: Bool, in page: any E2EPage) throws {
        guard let content = try Self.wizardSheet(in: page)?.contentView else { throw E2EError("no wizard sheet is up") }
        guard let box = Self.views(in: content, NSButton.self).first(where: { $0.title == title && $0.isEnabled })
        else { throw E2EError("the wizard has no enabled \"\(title)\" checkbox") }
        if (box.state == .on) != on { box.performClick(nil) }
    }

    func chooseImportMode(_ title: String, in page: any E2EPage) throws {
        guard let content = try Self.wizardSheet(in: page)?.contentView,
            let popup = Self.views(in: content, NSPopUpButton.self).first,
            let index = popup.itemTitles.firstIndex(of: title)
        else { throw E2EError("the wizard has no Space mode \"\(title)\"") }
        popup.selectItem(at: index)
        // A person's choice runs the pop up's action as the menu item does.
        popup.sendAction(popup.action, to: popup.target)
    }

    func markSidebar(in page: any E2EPage) throws -> E2ESidebarMark {
        E2ESidebarMark(graph: try Self.tabPage(page).controller.store.graph)
    }

    func sidebarMatches(_ mark: E2ESidebarMark, in page: any E2EPage) throws -> Bool {
        try Self.tabPage(page).controller.store.graph == mark.graph
    }

    func sidebarRows(skippingSpaces skipping: Int, in page: any E2EPage) throws -> [String] {
        let graph = try Self.tabPage(page).controller.store.graph
        var rows: [String] = []
        func add(_ container: SidebarItemID, depth: Int) {
            for item in graph.children(of: container) {
                switch item.data {
                case .tab(let tab):
                    rows.append("\(depth):\(item.title ?? (tab.savedTitle.isEmpty ? tab.savedURL : tab.savedTitle))")
                case .folder:
                    rows.append("\(depth):\(item.title ?? "")")
                case .split, .container:
                    rows.append("\(depth):split")
                }
                add(item.id, depth: depth + 1)
            }
        }
        for space in graph.spaces.dropFirst(skipping) {
            rows.append("0:\(space.title)")
            add(space.pinnedContainerID, depth: 1)
        }
        let favorites = graph.favoriteIDs(for: .default)
        if !favorites.isEmpty, let container = graph.favoritesContainerID(for: .default) {
            rows.append("0:Favorites")
            add(container, depth: 1)
        }
        return rows
    }

    func spaceTitles(in page: any E2EPage) throws -> [String] {
        try Self.tabPage(page).controller.store.graph.spaces.map(\.title)
    }

    func favoritesCount(in page: any E2EPage) throws -> Int {
        try Self.tabPage(page).controller.store.graph.favoriteIDs(for: .default).count
    }
}

extension E2ETestApp: E2EImportApp {
    func useImportFile(_ name: String?) throws {
        try adapter.requireActive(token, "choose the import file")
        try adapter.useImportFile(name)
    }

    func importFileRequests() throws -> Int {
        try adapter.requireActive(token, "read the import file requests")
        return adapter.importFileRequests()
    }

    func chooseImportMenuItem(in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose Import from Arc")
        try adapter.chooseMenuItem(path: ["File", ImportMenuFeature.title], in: page)
    }

    func importMenuItemEnabled(in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the Import from Arc item")
        return try adapter.importMenuItemEnabled(in: page)
    }

    func importWizard(in page: any E2EPage) throws -> E2EImportWizardState? {
        try adapter.requireActive(token, "read the import wizard")
        return try adapter.importWizardState(in: page)
    }

    func pressImportButton(_ title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "press \(title) in the import wizard")
        try adapter.pressImportButton(title, in: page)
    }

    func setImportCheckbox(_ title: String, on: Bool, in page: any E2EPage) throws {
        try adapter.requireActive(token, "set \(title) in the import wizard")
        try adapter.setImportCheckbox(title, on: on, in: page)
    }

    func chooseImportMode(_ title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose \(title) in the import wizard")
        try adapter.chooseImportMode(title, in: page)
    }

    func markSidebar(in page: any E2EPage) throws -> E2ESidebarMark {
        try adapter.requireActive(token, "mark the sidebar")
        return try adapter.markSidebar(in: page)
    }

    func sidebarMatches(_ mark: E2ESidebarMark, in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "compare the sidebar")
        return try adapter.sidebarMatches(mark, in: page)
    }

    func sidebarRows(skippingSpaces skipping: Int, in page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the sidebar rows")
        return try adapter.sidebarRows(skippingSpaces: skipping, in: page)
    }

    func spaceTitles(in page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the Space titles")
        return try adapter.spaceTitles(in: page)
    }

    func favoritesCount(in page: any E2EPage) throws -> Int {
        try adapter.requireActive(token, "count the Favorites")
        return try adapter.favoritesCount(in: page)
    }
}
