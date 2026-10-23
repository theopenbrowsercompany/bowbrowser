import AppKit
import BowCore

/// The Arc import wizard, one sheet on a browser window that walks through: what is read (consent), the file the
/// person picks, how Spaces come across with a checkbox per Arc Space, a preview tree, the import, and an Undo.
/// Nothing reads Arc's data before the file is picked, and nothing changes in the sidebar before Import.
///
/// History and bookmarks come from Arc's User Data folder, on their own from the consent step or after the sidebar
/// import from its last step: the person picks the folder, sees per profile what comes and which Bow profile it goes
/// to, chooses whether bookmarks come as a pinned folder, and imports. One Undo then takes out everything this wizard
/// added: the sidebar import and the bookmarks folder in one sidebar transaction, and the visits it added.
///
/// The choices and the preview come from BowCore (`ArcImportChoices`, `ArcImporter.preview`, `ChromiumImportPreview`);
/// this class only shows them and calls `ArcImporter.apply`, `ChromiumBookmarkImport.apply`,
/// `HistoryStore.importVisits` and their undos. It ends with its sheet: its reading task is cancelled, and the app
/// service forgets it.
@MainActor
final class ArcImportWizard: NSObject {
    enum Step: String {
        case consent, reading, failed, spaces, preview, history, importing, done
    }

    /// What the failed step's retry button picks again.
    private enum Retry {
        case sidebarFile, userDataFolder
    }

    /// The titles of the bookmarks choice, in `ChromiumBookmarksChoice.allCases` order.
    static let bookmarksChoiceTitles = ["Bookmarks as a pinned folder", "Skip bookmarks"]
    static let historyButtonTitle = "History and Bookmarks…"

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

    private var retry = Retry.sidebarFile
    private var readingText = "Reading the file…"
    private var historyPreview: ChromiumImportPreview?
    private var bookmarksChoice = ChromiumBookmarksChoice.pinnedFolder
    /// The visits the history import added, per history store, for Undo.
    private var historyRecords: [(store: HistoryStore, record: HistoryImportRecord)] = []
    /// The bookmarks folder the history import added, for Undo.
    private var bookmarksApplied: ChromiumBookmarksApplied?
    private var historyImported = false
    private var didUndo = false

    /// Whether the done step offers Undo: this wizard added something that is still there.
    private var canUndo: Bool { applied != nil || bookmarksApplied != nil || !historyRecords.isEmpty }
    /// Whether the done step offers the history import: once per wizard, and not after an Undo.
    private var canImportHistory: Bool { !historyImported && !didUndo }

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
        case .history: content = historyView()
        case .importing: content = importingView()
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
                "Bow reads only what you choose. Arc's sidebar file, StorableSidebar.json, brings your Spaces, "
                    + "folders, pinned tabs and Favorites."),
            body(
                "Arc's User Data folder brings your history and bookmarks: from it Bow reads only Local State, "
                    + "Bookmarks and a copy of History."),
            body(
                "Nothing leaves this Mac. Bow does not read your cookies, passwords or extensions, and it never "
                    + "changes Arc's files."),
            body(
                "You see a preview before anything is added, and you can undo the import afterwards."),
            buttons([
                button("Cancel", cancel: true) { [weak self] in self?.close() },
                button(Self.historyButtonTitle) { [weak self] in self?.chooseFolder() },
                button("Choose File…", isDefault: true) { [weak self] in self?.chooseFile() },
            ]),
        ])
    }

    private func readingView() -> NSView {
        column([
            heading("Import from Arc"),
            body(readingText),
            buttons([button("Cancel", cancel: true) { [weak self] in self?.cancelStep() }]),
        ])
    }

    private func failedView() -> NSView {
        let folder = retry == .userDataFolder
        return column([
            heading(folder ? "This folder cannot be imported" : "This file cannot be imported"),
            body(failureText),
            buttons([
                button("Cancel", cancel: true) { [weak self] in self?.cancelStep() },
                folder
                    ? button("Choose Another Folder…", isDefault: true) { [weak self] in self?.chooseFolder() }
                    : button("Choose Another File…", isDefault: true) { [weak self] in self?.chooseFile() },
            ]),
        ])
    }

    private func historyView() -> NSView {
        guard let preview = historyPreview, let controller else { return failedView() }
        let features = controller.appFeatures
        let service = service
        let lines = preview.lines(
            bookmarks: bookmarksChoice, profileName: { service.profileName($0, in: features) },
            fallbackSpaceTitle: controller.store.graph.activeSpace?.title ?? "your first Space")
        var views: [NSView] = [heading("History and bookmarks")]
        views.append(contentsOf: lines.map(body))
        let popup = ActionPopUp()
        popup.addItems(withTitles: Self.bookmarksChoiceTitles)
        popup.selectItem(at: ChromiumBookmarksChoice.allCases.firstIndex(of: bookmarksChoice) ?? 0)
        popup.setAccessibilityLabel("Bookmarks")
        popup.onChange = { [weak self] index in
            self?.bookmarksChoice = ChromiumBookmarksChoice.allCases[index]
            self?.show(.history)
        }
        views.append(popup)
        views.append(body("Cookies, passwords and extensions are not imported."))
        let importButton = button("Import", isDefault: true) { [weak self] in self?.performHistoryImport() }
        importButton.isEnabled = !preview.isEmpty(bookmarks: bookmarksChoice)
        views.append(
            buttons([button("Cancel", cancel: true) { [weak self] in self?.cancelStep() }, importButton]))
        return column(views)
    }

    private func importingView() -> NSView {
        column([heading("Import from Arc"), body("Importing your history…")])
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
        weak let controller = controller
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
        var row: [NSButton] = []
        if canUndo { row.append(button("Undo") { [weak self] in self?.undoImport() }) }
        if canImportHistory {
            row.append(button(Self.historyButtonTitle) { [weak self] in self?.chooseFolder() })
        }
        row.append(button("Done", isDefault: true, cancel: true) { [weak self] in self?.close() })
        return column([heading("Import from Arc"), body(doneText), buttons(row)])
    }

    // MARK: Actions

    /// Cancel on the reading, failed and history steps: a history import that follows a sidebar import goes back to
    /// the sidebar import's last step, where its Undo still is; otherwise the wizard closes.
    private func cancelStep() {
        if retry == .userDataFolder || step == .history, !doneText.isEmpty {
            readTask?.cancel()
            readTask = nil
            historyPreview = nil
            retry = .sidebarFile
            show(.done)
        } else {
            close()
        }
    }

    private func chooseFolder() {
        guard step == .consent || (step == .done && canImportHistory) || (step == .failed && retry == .userDataFolder)
        else { return }
        let back = step
        retry = .userDataFolder
        readingText = "Reading the folder…"
        show(.reading)
        let service = service
        let sheet = sheet
        readTask = Task { [weak self] in
            let url = await service.chooseUserDataFolder(for: sheet)
            guard let self, !ended, !Task.isCancelled else { return }
            guard let url else {
                if back != .failed { retry = .sidebarFile }
                show(back)
                return
            }
            let log = ChromiumFileLog()
            #if BOW_E2E  // E2E seam: the test reads which files the history step touched.
                service.e2eLastFileLog = log
            #endif
            do {
                let data = try await ArcImportFeature.readUserData(url, log: log)
                guard !ended, !Task.isCancelled else { return }
                prepareHistory(data)
            } catch {
                guard !ended, !Task.isCancelled else { return }
                failureText =
                    (error as? ChromiumUserData.Refusal)?.description
                    ?? "The folder could not be read (\(error.localizedDescription))."
                show(.failed)
            }
        }
    }

    private func prepareHistory(_ data: [ChromiumProfileData]) {
        guard let controller else { return }
        let features = controller.appFeatures
        let service = service
        let preview = ChromiumImportPreview(
            data: data, isKnown: { service.hasProfile($0, in: features) },
            fallback: controller.store.graph.activeSpace?.profileID ?? .default)
        guard !preview.isEmpty(bookmarks: .pinnedFolder) else {
            let problems = preview.lines(bookmarks: .pinnedFolder, profileName: { $0.rawValue }, fallbackSpaceTitle: "")
                .filter { !$0.contains(" visit") }
            failureText = (["The folder has no history or bookmarks to import."] + problems).joined(separator: " ")
            show(.failed)
            return
        }
        historyPreview = preview
        bookmarksChoice = .pinnedFolder
        show(.history)
    }

    private func performHistoryImport() {
        guard step == .history, let controller, let preview = historyPreview else { return }
        let folders = preview.bookmarkFolders(bookmarksChoice, in: controller.store.graph)
        var bookmarks = ChromiumBookmarksApplied()
        if !folders.isEmpty {
            let went = controller.changeSidebar { store in
                bookmarks = try ChromiumBookmarkImport.apply(folders, to: store)
            }
            guard went else {
                failureText = "The sidebar refused the bookmarks, so nothing was added."
                show(.failed)
                return
            }
        }
        bookmarksApplied = bookmarks.isEmpty ? nil : bookmarks
        historyImported = true
        var unopened: [String] = []
        var jobs: [(store: HistoryStore, visits: [HistoryImportVisit])] = []
        for entry in preview.entries where !entry.visits.isEmpty {
            guard let store = service.historyStore(for: entry.target.bowProfile, in: controller.appFeatures) else {
                unopened.append(entry.data.profile.displayName)
                continue
            }
            jobs.append((store, entry.visits))
        }
        show(.importing)
        let folderTitles = folders.map(\.title)
        readTask = Task { [weak self] in
            let results = await ArcImportFeature.importVisits(jobs)
            guard let self, !ended else { return }
            var added = 0
            var known = 0
            var failures = unopened.map { "the history of \($0) could not be opened" }
            for (job, result) in zip(jobs, results) {
                switch result {
                case .success(let record):
                    added += record.addedCount
                    known += record.skippedCount
                    if record.addedCount > 0 { historyRecords.append((job.store, record)) }
                case .failure(let error):
                    failures.append("history could not be written (\(error))")
                }
            }
            doneText = Self.historyDoneText(
                visits: added, knownVisits: known, bookmarks: bookmarks, folders: folderTitles,
                saveFailure: bookmarks.saveFailure, failures: failures)
            show(.done)
        }
    }

    private static func historyDoneText(
        visits: Int, knownVisits: Int, bookmarks: ChromiumBookmarksApplied, folders: [String], saveFailure: String?,
        failures: [String]
    ) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var text = "Imported \(plural(visits, "visit")) into your history"
        if folders.isEmpty {
            text += "."
        } else {
            text += " and \(plural(bookmarks.addedBookmarks, "bookmark")) into \(folders.joined(separator: ", "))."
        }
        if knownVisits > 0 { text += " \(plural(knownVisits, "visit")) were already in your history." }
        if bookmarks.knownBookmarks > 0 {
            text += " \(plural(bookmarks.knownBookmarks, "bookmark")) were already in the folder."
        }
        if let saveFailure { text += " Bow could not save your sidebar yet (\(saveFailure)); it keeps trying." }
        if !failures.isEmpty { text += " Not imported: " + failures.joined(separator: "; ") + "." }
        return text
    }

    private func chooseFile() {
        guard step == .consent || (step == .failed && retry == .sidebarFile) else { return }
        retry = .sidebarFile
        readingText = "Reading the file…"
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
        guard step == .done, let controller, canUndo else { return }
        var refusal: String?
        var undone = ArcImportUndone()
        var went = true
        if applied != nil || bookmarksApplied != nil {
            let sidebar = applied ?? ArcImportApplied()
            let bookmarks = bookmarksApplied
            went = controller.changeSidebar { store in
                do {
                    undone = try sidebar.undo(on: store, alongWith: bookmarks)
                } catch let error as ArcImportUndoError {
                    refusal = error.description
                }
            }
        }
        // A refusal or a sidebar that would not change keeps every record, so Undo can be tried again.
        var historyFailure: String?
        if refusal == nil, went {
            applied = nil
            bookmarksApplied = nil
            didUndo = true
            var kept: [(store: HistoryStore, record: HistoryImportRecord)] = []
            for entry in historyRecords {
                do {
                    try entry.store.removeImported(entry.record)
                } catch {
                    historyFailure = "\(error)"
                    kept.append(entry)
                }
            }
            historyRecords = kept
        }
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
        if let historyFailure {
            doneText +=
                " Some imported visits could not be taken out of your history (\(historyFailure)); try Undo again."
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
