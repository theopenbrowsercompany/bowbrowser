import AppKit
import BowCore

/// The Arc import wizard, one sheet on a browser window that walks through: what is read (consent), the file the
/// person picks, how Spaces come across with a checkbox per Arc Space, a preview tree, the import, and an Undo.
/// Nothing reads Arc's data before the file is picked, and nothing changes in the sidebar before Import.
///
/// The choices and the preview come from BowCore (`ArcImportChoices`, `ArcImporter.preview`); this class only shows
/// them and calls `ArcImporter.apply` and `ArcImportApplied.undo` on the window's store. It ends with its sheet: its
/// reading task is cancelled, and the app service forgets it.
@MainActor
final class ArcImportWizard: NSObject {
    enum Step: String {
        case consent, reading, failed, spaces, preview, done
    }

    private weak var controller: BrowserWindowController?
    private let service: ArcImportFeature
    private let sheet: NSWindow
    private var step = Step.consent
    private var ended = false
    private var readTask: Task<Void, Never>?
    private var closeObserver: (any NSObjectProtocol)?

    private var result: ArcImportResult?
    private var choices: ArcImportChoices?
    private var preview: ArcImportPreview?
    private var applied: ArcImportApplied?
    /// What the done screen says.
    private var doneText = ""
    private var failureText = ""
    private var previewRows: [PreviewItem] = []

    init(controller: BrowserWindowController, service: ArcImportFeature) {
        self.controller = controller
        self.service = service
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        super.init()
        sheet.title = "Import from Arc"
        sheet.isReleasedWhenClosed = false
    }

    // MARK: Lifecycle

    func begin(on window: NSWindow) {
        show(.consent)
        window.beginSheet(sheet) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        // The window closing takes the sheet with it: end first so nothing is left running.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Ends the sheet. Safe to call more than once.
    func close() {
        guard !ended else { return }
        // The file picker is a sheet on this one and must go first.
        if let child = sheet.attachedSheet { sheet.endSheet(child) }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { finish() }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        readTask?.cancel()
        readTask = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        sheet.orderOut(nil)
        service.didEnd(self)
    }

    // MARK: Steps

    private func show(_ next: Step) {
        guard !ended else { return }
        step = next
        sheet.defaultButtonCell = nil
        let content: NSView
        switch next {
        case .consent: content = consentView()
        case .reading: content = readingView()
        case .failed: content = failedView()
        case .spaces: content = spacesView()
        case .preview: content = previewView()
        case .done: content = doneView()
        }
        content.setAccessibilityIdentifier("arcImport.\(next.rawValue)")
        content.layoutSubtreeIfNeeded()
        sheet.contentView = content
        sheet.setContentSize(content.fittingSize)
        sheet.initialFirstResponder = nil
    }

    private func consentView() -> NSView {
        column([
            heading("Import from Arc"),
            body(
                "Bow reads one file that you choose: Arc's sidebar file, StorableSidebar.json. "
                    + "From it Bow takes your Spaces, folders, pinned tabs and Favorites."),
            body(
                "Nothing leaves this Mac. Bow does not read your cookies, passwords or history, and it never "
                    + "changes Arc's file."),
            body(
                "You see a preview before anything is added to your sidebar, and you can undo the import "
                    + "afterwards."),
            buttons([
                button("Cancel", cancel: true) { [weak self] in self?.close() },
                button("Choose File…", isDefault: true) { [weak self] in self?.chooseFile() },
            ]),
        ])
    }

    private func readingView() -> NSView {
        column([
            heading("Import from Arc"),
            body("Reading the file…"),
            buttons([button("Cancel", cancel: true) { [weak self] in self?.close() }]),
        ])
    }

    private func failedView() -> NSView {
        column([
            heading("This file cannot be imported"),
            body(failureText),
            buttons([
                button("Cancel", cancel: true) { [weak self] in self?.close() },
                button("Choose Another File…", isDefault: true) { [weak self] in self?.chooseFile() },
            ]),
        ])
    }

    private func spacesView() -> NSView {
        guard let result, var choices else { return failedView() }
        self.choices = choices
        var views: [NSView] = [heading("How should your Spaces come across?")]
        let modes: [(ArcSpaceImportMode, String)] = [
            (.arcSpaces, "Import Arc Spaces as Spaces"),
            (.spacesAsProfiles, "Give each Space its own profile"),
            (.skipSpaces, "Skip Spaces (bring only Favorites)"),
        ]
        let popup = ActionPopUp()
        popup.addItems(withTitles: modes.map(\.1))
        popup.selectItem(at: modes.firstIndex { $0.0 == choices.mode } ?? 0)
        popup.setAccessibilityLabel("Space mode")
        views.append(popup)

        // The boxes' closures hold refresh, so refresh holds the boxes and the controller weakly: a strong hold
        // would keep this view, the wizard and its sheet window alive after the sheet ends.
        let spaceBoxes = NSHashTable<WizardButton>.weakObjects()
        weak var controller = controller
        let continueButton = button("Continue", isDefault: true) { [weak self] in self?.showPreview() }
        func refresh() {
            for box in spaceBoxes.allObjects { box.isEnabled = choices.choosesSpaces }
            let empty = choices.preview(of: result, in: controller?.store.graph).isEmpty
            continueButton.isEnabled = !empty
        }
        popup.onChange = { [weak self] index in
            choices.mode = modes[index].0
            self?.choices = choices
            refresh()
        }
        views.append(body("Spaces to bring"))
        for space in result.spaces {
            let box = checkbox(
                space.title.isEmpty ? "Untitled Space" : space.title, on: choices.checkedSpaceIDs.contains(space.id)
            ) {
                [weak self] on in
                if on { choices.checkedSpaceIDs.insert(space.id) } else { choices.checkedSpaceIDs.remove(space.id) }
                self?.choices = choices
                refresh()
            }
            spaceBoxes.add(box)
            views.append(box)
        }
        if result.spaces.isEmpty { views.append(body("The file has no Spaces.")) }
        views.append(
            checkbox("Include Favorites", on: choices.includeFavorites) { [weak self] on in
                choices.includeFavorites = on
                self?.choices = choices
                refresh()
            })
        views.append(
            checkbox("Include unpinned tabs", on: choices.includeUnpinnedTabs) { [weak self] on in
                choices.includeUnpinnedTabs = on
                self?.choices = choices
                refresh()
            })
        views.append(
            buttons([
                button("Cancel", cancel: true) { [weak self] in self?.close() },
                button("Back") { [weak self] in self?.show(.consent) },
                continueButton,
            ]))
        refresh()
        return column(views)
    }

    private func showPreview() {
        guard let result, let choices else { return }
        let preview = choices.preview(of: result, in: controller?.store.graph)
        self.preview = preview
        previewRows = PreviewItem.tree(from: preview.rows)
        show(.preview)
    }

    private func previewView() -> NSView {
        guard let preview else { return failedView() }
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.selectionHighlightStyle = .none
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Preview")
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let counts = preview.counts
        let summary =
            "\(counts.spaces) Spaces, \(counts.folders) folders, \(counts.tabs) tabs, \(counts.favorites) Favorites"
        var views: [NSView] = [heading("Preview"), body(summary), scroll]
        let notes = preview.omissions.map { "\($0.label): \($0.reason.summary)" }
        if !notes.isEmpty { views.append(body("Not brought: " + notes.joined(separator: "; "))) }
        if !preview.skippedByImporter.isEmpty {
            views.append(body("Left out of the file: \(preview.skippedByImporter.count) items Bow cannot import."))
        }
        views.append(
            buttons([
                button("Cancel", cancel: true) { [weak self] in self?.close() },
                button("Back") { [weak self] in self?.show(.spaces) },
                button("Import", isDefault: true) { [weak self] in self?.performImport() },
            ]))
        return self.column(views)
    }

    private func doneView() -> NSView {
        var rows: [NSView] = [heading("Import from Arc"), body(doneText)]
        if applied != nil {
            rows.append(
                buttons([
                    button("Undo") { [weak self] in self?.undoImport() },
                    button("Done", isDefault: true, cancel: true) { [weak self] in self?.close() },
                ]))
        } else {
            rows.append(buttons([button("Done", isDefault: true, cancel: true) { [weak self] in self?.close() }]))
        }
        return column(rows)
    }

    // MARK: Actions

    private func chooseFile() {
        guard step == .consent || step == .failed else { return }
        show(.reading)
        readTask = Task { [weak self] in
            guard let self else { return }
            guard let url = await service.chooseFile(for: sheet), !ended, !Task.isCancelled else {
                if !ended { show(.consent) }
                return
            }
            do {
                let parsed = try await ArcImportFeature.read(url)
                guard !ended, !Task.isCancelled else { return }
                guard !parsed.spaces.isEmpty || parsed.favorites.contains(where: { !$0.items.isEmpty }) else {
                    failureText = "The file has no Spaces or Favorites to import."
                    show(.failed)
                    return
                }
                result = parsed
                choices = ArcImportChoices(for: parsed)
                show(.spaces)
            } catch {
                guard !ended, !Task.isCancelled else { return }
                failureText = ArcImportFeature.message(for: error)
                show(.failed)
            }
        }
    }

    private func performImport() {
        guard step == .preview, let controller, let preview else { return }
        var applied = ArcImportApplied()
        let went = controller.changeSidebar { store in applied = try ArcImporter.apply(preview, to: store) }
        guard went else {
            failureText = "The sidebar refused the import, so nothing was added."
            show(.failed)
            return
        }
        // The profiles the new Spaces use must exist before their tabs can open. If that fails the import is taken
        // out again, so a Space never arrives without its profile.
        do {
            try service.registerProfiles(
                of: applied, in: controller.store, using: controller.appFeatures.require(ProfileRegistryStore.self))
        } catch ProfileRegistryError.saveFailed(let reason) {
            FileHandle.standardError.write(Data("bow: the imported profiles could not be saved: \(reason)\n".utf8))
        } catch {
            controller.changeSidebar { store in _ = try? applied.undo(on: store) }
            failureText = "The profiles for the imported Spaces could not be set up (\(error)), so nothing was added."
            show(.failed)
            return
        }
        self.applied = applied
        var text =
            "Imported \(applied.spaceIDs.count) Spaces with \(applied.spaceItemIDs.count) folders and tabs, and "
            + "\(applied.favoriteItemIDs.count) Favorites."
        if applied.spaceIDs.isEmpty { text = "Imported \(applied.favoriteItemIDs.count) Favorites." }
        if applied.isEmpty { text = "Everything in the file is already in your sidebar, so nothing was added." }
        if let failure = applied.saveFailure {
            text += " Bow could not save your sidebar yet (\(failure)); it keeps trying."
        }
        doneText = text
        if applied.isEmpty { self.applied = nil }
        show(.done)
    }

    private func undoImport() {
        guard step == .done, let controller, let applied else { return }
        var refusal: String?
        var undone = ArcImportUndone()
        let went = controller.changeSidebar { store in
            do {
                undone = try applied.undo(on: store)
            } catch let error as ArcImportUndoError {
                refusal = error.description
            }
        }
        // A refusal or a sidebar that would not change keeps the record, so Undo can be tried again.
        if refusal == nil, went { self.applied = nil }
        if let refusal {
            doneText = "The import was not undone: \(refusal)."
        } else if went {
            doneText =
                "The import is undone."
                + (undone.keptItemIDs.isEmpty
                    ? "" : " Tabs you added to the imported Spaces moved to your first Space.")
        } else {
            doneText = "The import could not be undone."
        }
        if let failure = undone.saveFailure {
            doneText += " Bow could not save your sidebar yet (\(failure)); it keeps trying."
        }
        show(.done)
    }

    // MARK: View helpers

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 15)
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 520
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return label
    }

    private func column(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = true
        return stack
    }

    private func buttons(_ views: [NSButton]) -> NSView {
        // Buttons sit at the trailing edge, the default one last, as AppKit sheets lay them out.
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 8
        container.distribution = .gravityAreas
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 520).isActive = true
        for view in views { container.addView(view, in: .trailing) }
        return container
    }

    private func button(
        _ title: String, isDefault: Bool = false, cancel: Bool = false, action: @escaping () -> Void
    ) -> WizardButton {
        let button = WizardButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.onPress = action
        button.target = button
        button.action = #selector(WizardButton.pressed)
        if isDefault { button.keyEquivalent = "\r" }
        if cancel {
            // A button that is both the default and the cancel button (Done) keeps Return; Escape reaches it through
            // the sheet's cancel operation.
            if !isDefault { button.keyEquivalent = "\u{1b}" }
        }
        if isDefault { sheet.defaultButtonCell = button.cell as? NSButtonCell }
        return button
    }

    private func checkbox(_ title: String, on: Bool, action: @escaping (Bool) -> Void) -> WizardButton {
        let box = WizardButton(title: title, target: nil, action: nil)
        box.setButtonType(.switch)
        box.isCheckbox = true
        box.state = on ? .on : .off
        box.target = box
        box.action = #selector(WizardButton.pressed)
        box.onPress = { [unowned box] in action(box.state == .on) }
        return box
    }
}

/// A button that runs a closure when pressed.
@MainActor
final class WizardButton: NSButton {
    var onPress: (() -> Void)?
    /// True for a checkbox, false for a push button.
    var isCheckbox = false
    @objc func pressed() { onPress?() }
}

/// A pop up button that reports the chosen index.
@MainActor
private final class ActionPopUp: NSPopUpButton {
    var onChange: ((Int) -> Void)?

    init() {
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func changed() { onChange?(indexOfSelectedItem) }
}

// MARK: Preview tree

/// One node of the preview outline, built from `ArcImportPreview.rows`.
final class PreviewItem {
    let row: ArcImportPreviewRow
    var children: [PreviewItem] = []

    init(row: ArcImportPreviewRow) { self.row = row }

    /// The top level items of the rows' tree, each row under the nearest earlier row one level up.
    static func tree(from rows: [ArcImportPreviewRow]) -> [PreviewItem] {
        var top: [PreviewItem] = []
        var path: [PreviewItem] = []
        for row in rows {
            let item = PreviewItem(row: row)
            path.removeLast(max(0, path.count - row.depth))
            if let parent = path.last { parent.children.append(item) } else { top.append(item) }
            path.append(item)
        }
        return top
    }
}

extension ArcImportWizard: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? PreviewItem)?.children.count ?? previewRows.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? PreviewItem)?.children[index] ?? previewRows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? PreviewItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? PreviewItem else { return nil }
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: item.row.title)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        let symbol: String =
            switch item.row.kind {
            case .space: "square.grid.2x2"
            case .favorites: "star"
            case .section: "clock"
            case .folder: "folder"
            case .tab: "globe"
            case .splitView: "rectangle.split.2x1"
            }
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
