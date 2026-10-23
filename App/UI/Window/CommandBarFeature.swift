import AppKit
import BowCore

/// The command bar: a panel floating over the page with a field and one merged list of the typed address, a search,
/// this window's tabs in every Space and the shown tab's profile's history.
///
/// Cmd+T (File > New Tab) opens it empty, and choosing an address opens it in a new tab in the active Space's today
/// section. Cmd+L (View > Open Location) opens it filled with the shown page's address, all selected, and choosing an
/// address loads it in that tab. Choosing an open tab switches to it, and to its Space, in both. Escape or a click
/// outside the panel closes it without changes. The shortcuts are claimed before the page (`KeyShortcuts`), so a page
/// that listens for keys never sees them.
@MainActor
final class CommandBarFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    /// What choosing an address does.
    enum Mode {
        /// Opened with Cmd+T: an address opens in a new tab.
        case newTab
        /// Opened with Cmd+L over `tab`: an address loads in that tab.
        case currentTab(any EngineTab)
    }

    /// The app commands the bar offers by name, each sent down the responder chain as its menu item's action when
    /// chosen. A command's feature adds one line here with its menu item.
    static let commands: [(command: CommandBarCommand, action: Selector)] = []

    private unowned let window: BrowserWindowController
    private let historyStores: HistoryStores
    private let activity: TabActivityLog
    let overlay = CommandBarOverlay()
    var panel: CommandBarPanel { overlay.panel }

    /// Nil while the bar is closed.
    private(set) var mode: Mode?
    /// The rows shown, best first.
    private(set) var results: [CommandBarResult] = []
    /// The highlighted row, which Enter chooses; nil when no row shows.
    private(set) var selectedIndex: Int?
    /// The text whose results are complete (every source answered or timed out); nil while a query runs.
    private(set) var settledQuery: String?

    /// Counts queries, so the answers of a query that a keystroke replaced are dropped.
    private var generation = 0
    /// The newest query that has shown at least one update.
    private var shownGeneration = 0
    private var queryTask: Task<Void, Never>?
    /// Whether the person picked the highlighted row with an arrow key since the text last changed.
    private var selectionPicked = false
    /// Enter pressed before the current text's first results showed: choose once they do.
    private var chooseWhenShown = false
    /// The command bar names tabs by UUID; sidebar item IDs are usually lowercase UUIDs, and any other item gets one
    /// here for as long as the window lives.
    private var tabUUIDs: [SidebarItemID: UUID] = [:]
    private var tabItems: [UUID: SidebarItemID] = [:]

    var isOpen: Bool { mode != nil }

    init(window: BrowserWindowController) {
        self.window = window
        historyStores = window.appFeatures.require(HistoryStores.self)
        activity = window.appFeatures.require(TabActivityLog.self)
        super.init()
        overlay.isHidden = true
        if let content = window.window?.contentView {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(overlay)
            let pageArea = window.pageArea
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: content.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                panel.centerXAnchor.constraint(equalTo: pageArea.centerXAnchor),
                panel.topAnchor.constraint(equalTo: pageArea.topAnchor, constant: 72),
            ])
        }
        overlay.onClickOutside = { [weak self] in self?.close() }
        panel.onTextChange = { [weak self] text in self?.runQuery(text) }
        panel.onMove = { [weak self] step in self?.moveSelection(step) }
        panel.onEnter = { [weak self] in self?.chooseSelected() }
        panel.onClickRow = { [weak self] index in
            self?.selectedIndex = index
            self?.chooseSelected()
        }
        panel.onCancel = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// File > New Tab (Cmd+T) is the window core's; View > Open Location (Cmd+L) and Close Command Bar are the bar's.
    /// Escape has no menu shortcut: a menu item claims its key equivalent even while disabled, which would take
    /// Escape from the find bar and the page. The bar's field and `handleKeyBeforePage` answer it instead.
    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.view.addItem(.separator())
        menus.view.addItem(withTitle: "Open Location…", action: #selector(openLocation(_:)), keyEquivalent: "l")
        menus.view.addItem(withTitle: "Close Command Bar", action: #selector(closeCommandBar(_:)), keyEquivalent: "")
    }

    // MARK: Commands

    /// File > New Tab and Cmd+T from the menu, and the sidebar's New Tab button (Arc's button opens the command bar
    /// too). Other callers (the start screen's button) open a tab directly.
    func handleNewTab(_ sender: Any?) -> Bool {
        guard sender is NSMenuItem || sender is SidebarView else { return false }
        open(.newTab)
        return true
    }

    /// View > Open Location (Cmd+L): the bar over the shown tab, filled with its address.
    @objc func openLocation(_ sender: Any?) {
        guard let tab = shownTab else { return }
        open(.currentTab(tab))
    }

    /// A click on the sidebar's URL field: the bar over the shown tab, filled with its address, as Cmd+L opens it;
    /// with no tab shown (an empty Space), the bar to open a new tab, as Cmd+T opens it.
    @objc func openFromURLField(_ sender: Any?) {
        guard let tab = shownTab else { return open(.newTab) }
        open(.currentTab(tab))
    }

    /// View > Close Command Bar.
    @objc func closeCommandBar(_ sender: Any?) {
        close()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openLocation(_:)): shownTab != nil
        case #selector(closeCommandBar(_:)): isOpen
        default: true
        }
    }

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard let shortcut = KeyShortcuts.shortcut(for: event, claimedBy: .commandBar) else { return false }
        switch shortcut {
        case .newTab:
            open(.newTab)
        case .changeURL:
            guard let target = shownTab ?? (tab.isClosed ? nil : tab) else { return false }
            open(.currentTab(target))
        case .closeCommandBar:
            guard isOpen else { return false }
            close()
        default:
            return false
        }
        return true
    }

    /// The tab the window shows, unless it has closed.
    private var shownTab: (any EngineTab)? {
        guard let tab = window.selectedTab, !tab.isClosed else { return nil }
        return tab
    }

    // MARK: Window events

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        guard let mode else { return }
        // The bar over a tab closes once another tab shows, and every bar closes with the window's last tab.
        if tab == nil { return close() }
        if case .currentTab(let target) = mode, target !== tab { close() }
    }

    func tabDidClose(_ tab: any EngineTab) {
        if case .currentTab(let target) = mode, target === tab { close() }
    }

    func activeSpaceChanged(_ space: SidebarSpace) {
        // Another Space on screen: the bar was opened for the one before.
        close()
    }

    func storeChanged(_ graph: SidebarGraph) {
        // Tabs opened, closed or renamed: list them as they are now, keeping the highlighted row.
        if isOpen { runQuery(panel.field.stringValue, keepSelection: true) }
    }

    // MARK: Opening and closing

    /// Shows the bar in `mode` with the keyboard in its field, clearing what it held before.
    func open(_ mode: Mode) {
        guard window.window != nil, !window.isClosing else { return }
        self.mode = mode
        results = []
        selectedIndex = nil
        selectionPicked = false
        chooseWhenShown = false
        panel.show([], selected: nil)
        switch mode {
        case .newTab: panel.field.stringValue = ""
        case .currentTab(let tab): panel.field.stringValue = tab.state.url?.absoluteString ?? ""
        }
        overlay.isHidden = false
        window.window?.makeFirstResponder(panel.field)
        // Selects the whole text, so typing replaces the address.
        panel.field.selectText(nil)
        runQuery(panel.field.stringValue)
    }

    /// Hides the bar, changing nothing, and gives the keyboard back to the page when the bar had it.
    func close() {
        guard isOpen else { return }
        let hadKeyboard = hide()
        if hadKeyboard { window.webView.focusAttachedTab() }
    }

    /// Hides the bar and stops its query. Returns whether its field had the keyboard.
    @discardableResult
    private func hide() -> Bool {
        let hadKeyboard = panel.field.currentEditor() != nil
        mode = nil
        generation += 1
        queryTask?.cancel()
        queryTask = nil
        chooseWhenShown = false
        results = []
        selectedIndex = nil
        settledQuery = nil
        panel.show([], selected: nil)
        if hadKeyboard { window.window?.makeFirstResponder(nil) }
        overlay.isHidden = true
        return hadKeyboard
    }

    // MARK: Querying

    /// Asks every source for `text` again. Each source's answer updates the list as it comes; a newer query drops
    /// the answers of this one. New text highlights the best row; `keepSelection` keeps the highlighted one.
    private func runQuery(_ text: String, keepSelection: Bool = false) {
        generation += 1
        let current = generation
        if !keepSelection {
            selectedIndex = nil
            selectionPicked = false
        }
        queryTask?.cancel()
        settledQuery = nil
        let tabs = openTabs()
        let history = historyStore().map(HistoryStoreSource.init(store:))
        queryTask = Task { [weak self] in
            let registry = CommandBarRegistry()
            await registry.register(AddressInputProvider())
            await registry.register(OpenTabsProvider(source: OpenTabSnapshot(tabs: tabs)))
            await registry.register(CommandsProvider(commands: Self.commands.map(\.command)))
            if let history { await registry.register(HistoryProvider(source: history)) }
            for await update in await registry.updates(for: text) {
                guard let self, self.generation == current else { return }
                self.show(update, for: text, generation: current)
            }
            guard let self, self.generation == current else { return }
            self.settledQuery = text
        }
    }

    /// Shows `update`, keeping the highlighted row when it is still listed. Typed text highlights the best row;
    /// blank text highlights none (the open tabs list), so Enter does nothing until an arrow key picks a row.
    private func show(_ update: [CommandBarResult], for text: String, generation: Int) {
        // A row the person picked with the arrow keys stays picked while the list updates; otherwise the best row
        // is highlighted, also when a slower source's answer puts a better row first.
        let selectedID =
            selectionPicked ? selectedIndex.flatMap { results.indices.contains($0) ? results[$0].id : nil } : nil
        results = update
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let picked = selectedID.flatMap { id in update.firstIndex { $0.id == id } }
        if picked == nil { selectionPicked = false }
        selectedIndex = picked ?? (update.isEmpty || blank ? nil : 0)
        shownGeneration = generation
        panel.show(update, selected: selectedIndex)
        if chooseWhenShown {
            chooseWhenShown = false
            chooseSelected()
        }
    }

    private func moveSelection(_ step: Int) {
        guard !results.isEmpty else { return }
        let current = selectedIndex ?? (step > 0 ? -1 : results.count)
        selectedIndex = min(max(current + step, 0), results.count - 1)
        selectionPicked = true
        panel.select(selectedIndex)
    }

    /// Every tab of the window's sidebar, in every Space and in Favorites, with its live title and address when it
    /// has a page in the Space on screen and its saved ones otherwise.
    private func openTabs() -> [OpenTabInfo] {
        let graph = window.store.graph
        var live: [SidebarItemID: BrowserTab] = [:]
        for tab in window.tabList.tabs {
            if let item = window.sidebarItemID(for: tab.id) { live[item] = tab }
        }
        let spaces = OpenTabSpaces(graph: graph, itemID: { [tabItems] in tabItems[$0] })
        var result: [OpenTabInfo] = []
        for (item, entry) in graph.items {
            guard let saved = entry.tab else { continue }
            let runtime = live[item]
            guard
                let url = runtime?.url ?? graph.pinnedURL(of: item) ?? saved.savedPageURL,
                url.scheme != nil
            else { continue }
            let title = runtime?.title.nilIfEmpty ?? entry.title?.nilIfEmpty ?? saved.savedTitle
            let id = uuid(for: item)
            result.append(
                OpenTabInfo(
                    id: id, title: title, url: url, lastActive: activity.lastActive(item) ?? .distantPast,
                    space: spaces.space(of: id)))
        }
        return result
    }

    private func uuid(for item: SidebarItemID) -> UUID {
        if let id = tabUUIDs[item] { return id }
        let id = UUID(uuidString: item.rawValue) ?? UUID()
        tabUUIDs[item] = id
        tabItems[id] = item
        return id
    }

    /// The history of the shown tab's profile, or of the Space on screen when no tab shows.
    private func historyStore() -> HistoryStore? {
        let profile = shownTab.flatMap { window.engineProfile(of: $0) } ?? window.activeProfile
        guard let profile else { return nil }
        return historyStores.store(for: profile.profileID, isPersistent: { profile.isPersistent })
    }

    // MARK: Choosing

    /// Carries out the highlighted row, then closes the bar. Before the current text's first results show, waits for
    /// them. With no row (blank text) it does nothing.
    private func chooseSelected() {
        guard let mode else { return }
        guard shownGeneration == generation else {
            chooseWhenShown = true
            return
        }
        guard let index = selectedIndex, results.indices.contains(index) else { return }
        let result = results[index]
        let hadKeyboard = hide()
        switch result.action {
        case .switchToTab(let id):
            switchToTab(id)
        case .runCommand(let id):
            if let action = Self.commands.first(where: { $0.command.id == id })?.action {
                NSApp.sendAction(action, to: window, from: self)
            }
        case .navigate(let url):
            switch mode {
            case .newTab:
                window.openTab(url: url)
            case .currentTab(let tab):
                if !tab.isClosed { tab.load(url) }
            }
        }
        if hadKeyboard { window.webView.focusAttachedTab() }
    }

    /// Shows the tab `id` names, first bringing its Space on screen when it lives in another.
    private func switchToTab(_ id: UUID) {
        guard let item = tabItems[id] else { return }
        if let runtime = window.tabList.tabs.first(where: { window.sidebarItemID(for: $0.id) == item }) {
            window.select(runtime.id)
            return
        }
        let items = tabItems
        window.changeSidebar { store in
            try store.selectOpenTab(id, itemID: { items[$0] })
        }
    }
}

/// The tabs the window had when a query started, handed to the open tabs provider off the main thread.
private struct OpenTabSnapshot: OpenTabSource {
    let tabs: [OpenTabInfo]

    func openTabs() async -> [OpenTabInfo] { tabs }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
