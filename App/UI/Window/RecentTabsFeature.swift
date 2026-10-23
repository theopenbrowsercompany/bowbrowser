import AppKit
import BowCore

/// Ctrl+Tab by recency (spec/ctrl-tab-recency.md): holding Ctrl and pressing Tab shows an overlay over the page card
/// that lists the window's tabs, in every Space, from the one used last to the one used longest ago, each with its
/// Space. The first Tab highlights the previous tab, so a quick Ctrl+Tab goes back to where the person just was; Tab
/// steps on, Shift+Tab steps back, and both wrap. Releasing Ctrl shows the highlighted tab (bringing its Space on
/// screen when it lives in another), and Escape closes the overlay and changes nothing.
///
/// The keys are claimed before the page (`KeyShortcuts`). Chromium may not hand the page's key path the Ctrl release,
/// so while the overlay shows a local `flagsChanged` event monitor watches the modifiers; it exists only then.
@MainActor
final class RecentTabsFeature: NSResponder, BrowserWindowFeature {
    private unowned let window: BrowserWindowController
    let panel = RecentTabsPanel()

    /// The window's tabs, most recently shown first. Each window has its own.
    private(set) var recency = RecencyList<SidebarItemID>()
    /// The session in progress, nil while the overlay is closed.
    private var switcher: RecencySwitch<SidebarItemID>?
    private var flagsMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    var isOpen: Bool { switcher != nil }
    /// Whether the Ctrl release monitor is installed: only while the overlay shows.
    var isMonitoring: Bool { flagsMonitor != nil }

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        panel.isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.window?.contentView {
            content.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.centerXAnchor.constraint(equalTo: window.pageArea.centerXAnchor),
                panel.centerYAnchor.constraint(equalTo: window.pageArea.centerYAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Window events

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        guard let tab, let item = window.modelID(of: tab).flatMap({ window.sidebarItemID(for: $0) }) else { return }
        recency.use(item)
    }

    func storeChanged(_ graph: SidebarGraph) {
        recency.sync(open: Self.tabItems(in: graph))
        if isOpen { refreshOverlay() }
    }

    // MARK: Keys

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard let shortcut = KeyShortcuts.shortcut(for: event, claimedBy: .recentTabs) else { return false }
        switch shortcut {
        case .recentTabs: step(1)
        case .recentTabsBack: step(-1)
        case .closeCommandBar:
            guard isOpen else { return false }
            cancel()
        default: return false
        }
        return true
    }

    /// Ctrl+Tab or Ctrl+Shift+Tab: starts a session when none runs, then moves the highlight.
    private func step(_ delta: Int) {
        guard !window.isClosing else { return }
        if switcher == nil {
            recency.sync(open: Self.tabItems(in: window.store.graph))
            // With fewer than two tabs there is nowhere to go: the key does nothing.
            guard recency.ids.count >= 2, var started = recency.beginSwitch() else { return }
            started.step(delta)
            begin(started)
        } else {
            switcher?.step(delta)
            refreshOverlay()
        }
    }

    private func begin(_ started: RecencySwitch<SidebarItemID>) {
        switcher = started
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
            return event
        }
        if let nsWindow = window.window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nsWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
        refreshOverlay()
        panel.isHidden = false
    }

    /// Every flags change while the overlay shows (the monitor sees them for every window); the Ctrl release ends it.
    func handleFlagsChanged(_ event: NSEvent) {
        guard isOpen, !event.modifierFlags.contains(.control) else { return }
        commit()
    }

    // MARK: Ending

    /// Releasing Ctrl: the highlighted tab, or the next one still open, becomes the shown tab.
    private func commit() {
        guard let finished = switcher else { return }
        end()
        guard let item = recency.commit(finished) else { return }
        show(item)
    }

    /// Escape, or the window losing the keyboard: closes the overlay and keeps the shown tab.
    private func cancel() {
        guard isOpen else { return }
        end()
    }

    private func end() {
        switcher = nil
        panel.isHidden = true
        panel.show([], selected: 0)
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Shows the tab of sidebar item `item`, first bringing its Space on screen when it lives in another.
    private func show(_ item: SidebarItemID) {
        if let runtime = window.tabList.tabs.first(where: { window.sidebarItemID(for: $0.id) == item }) {
            window.select(runtime.id)
            return
        }
        window.changeSidebar { store in try store.selectTab(item) }
    }

    // MARK: Overlay

    /// The rows the overlay lists: the session's snapshot without the tabs that have closed since, and the one that
    /// releasing Ctrl would show.
    var overlayRows: (rows: [RecentTabRow], highlighted: Int?) {
        guard let switcher else { return ([], nil) }
        let graph = window.store.graph
        let order = switcher.order.filter { recency.contains($0) }
        let count = switcher.order.count
        let target = (0..<count).lazy.map { switcher.order[(switcher.index + $0) % count] }.first {
            recency.contains($0)
        }
        let rows = order.map { row(for: $0, in: graph) }
        return (rows, target.flatMap { target in order.firstIndex(of: target) })
    }

    private func refreshOverlay() {
        let (rows, highlighted) = overlayRows
        guard !rows.isEmpty else { return cancel() }
        let sidebar = window.feature(SidebarFeature.self)
        panel.show(rows.map { ($0, sidebar?.favicon(for: $0.item)) }, selected: highlighted ?? 0)
    }

    private func row(for item: SidebarItemID, in graph: SidebarGraph) -> RecentTabRow {
        let entry = graph[item]
        let runtime = window.tabList.tabs.first { window.sidebarItemID(for: $0.id) == item }
        let url = runtime?.url ?? graph.pinnedURL(of: item) ?? entry?.tab?.savedPageURL
        let title =
            [runtime?.title, entry?.title, entry?.tab?.savedTitle].compactMap { $0 }.first { !$0.isEmpty }
            ?? url?.host ?? url?.absoluteString ?? "New Tab"
        let space = graph.spaceID(containing: item).flatMap { graph.space($0) }.map(SpaceSummary.init)
        return RecentTabRow(item: item, title: title, space: space)
    }

    /// The tabs the window can switch to: every tab item of the sidebar, in item order.
    private static func tabItems(in graph: SidebarGraph) -> [SidebarItemID] {
        graph.items.compactMap { $0.value.tab == nil ? nil : $0.key }.sorted { $0.rawValue < $1.rawValue }
    }
}
