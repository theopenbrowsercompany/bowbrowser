import AppKit
import BowCore

/// Lists a window's loaded tabs, in every Space, for the app's `TabUnloader`, and unloads the ones it picks.
///
/// Never offered: the tab the window shows, every tab while the window closes, shows a sheet (a leave prompt or a
/// page's dialog) or the app shows a modal panel, which an unload would take away unanswered (the next pass tries
/// again), a tab whose page dialog waits for the tab to be shown (`PageDialogsFeature`), a tab whose row left the
/// sidebar,
/// a tab still loading (a navigation under way), every tab of a profile with a download under way, since the
/// engine cannot tell which page a download came from and destroying that page would cancel it, a tab the person
/// typed into since its page last committed a navigation (form input with no beforeunload handler would be lost, as
/// Chromium's own discarding also judges), and a pinned tab or Favorite showing another page than its saved address
/// (loading it again returns to that address, so the page it was on would be lost). The policy itself
/// spares tabs using the camera or microphone, tabs playing sound and tabs that stopped less than 30 seconds ago
/// (CEF 156 reports no audible state, so those exemptions apply only once an engine reports sound).
///
/// A tab this feature unloaded shows `UnloadPlaceholderView` over the page area when it is shown again alone, until
/// its page has loaded or failed to (`UnloadPlaceholder`).
@MainActor
final class TabUnloadFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?
    private let unloader: TabUnloader
    private let activity: TabActivityLog
    private var loaded: [TabID: Entry] = [:]
    /// Pages the person typed into, until their next main frame commit.
    private var typedInto: Set<TabID> = []
    /// Pages playing sound now, and when each page that stopped last stopped, by the unloader's clock.
    private var audible: Set<TabID> = []
    private var lastAudible: [TabID: Date] = [:]
    /// Sidebar tabs this feature unloaded, until they load again, with what their placeholder shows, read as they
    /// unloaded.
    private var unloadedItems: [SidebarItemID: Card] = [:]
    /// Pages loading again after an unload, until their page has loaded or failed to.
    private var reloading: [TabID: (item: SidebarItemID, card: Card)] = [:]
    /// Pages this feature asked the engine to unload, until it answers, with their sidebar tab and card.
    private var unloading: [TabID: (item: SidebarItemID, card: Card)] = [:]

    /// What a placeholder shows: the tab's title, its address's host and its site icon.
    private struct Card {
        let title: String
        let host: String
        let icon: NSImage?
    }
    /// The placeholder on screen and the page it stands in for.
    private var placeholder: (tab: TabID, item: SidebarItemID, view: UnloadPlaceholderView)?

    private struct Entry {
        let tab: any EngineTab
        let item: SidebarItemID
        let id = UUID()
        /// When the page loaded, by the unloader's clock: a tab never selected counts as used then.
        let loadedAt: Date
    }

    /// One loaded tab the unloader may consider, and what the policy needs to know about it.
    struct Candidate {
        let tab: any EngineTab
        let unloadTab: UnloadTab
    }

    init(window: BrowserWindowController) {
        self.window = window
        unloader = window.appFeatures.require(TabUnloader.self)
        activity = window.appFeatures.require(TabActivityLog.self)
        super.init()
        unloader.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func tabOpened(_ tab: any EngineTab, item: SidebarItemID) {
        loaded[tab.tabID] = Entry(tab: tab, item: item, loadedAt: unloader.clock.now)
        if let card = unloadedItems.removeValue(forKey: item) { reloading[tab.tabID] = (item, card) }
    }

    func tabDidClose(_ tab: any EngineTab) {
        loaded[tab.tabID] = nil
        typedInto.remove(tab.tabID)
        audible.remove(tab.tabID)
        lastAudible[tab.tabID] = nil
        if reloading.removeValue(forKey: tab.tabID) != nil { updatePlaceholder(ended: "close") }
    }

    /// A new page committed: what was typed into the old one went with it. Sound starting and stopping is noted, and
    /// a page loading again after an unload ends its placeholder once it has loaded or failed to.
    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .didCommit: typedInto.remove(tab.tabID)
        case .unloaded:
            if let (item, card) = unloading[tab.tabID] { unloadedItems[item] = card }
        case .stateChanged(let state):
            if state.isAudible {
                audible.insert(tab.tabID)
            } else if audible.remove(tab.tabID) != nil {
                lastAudible[tab.tabID] = unloader.clock.now
            }
        default: break
        }
        if reloading[tab.tabID] != nil, UnloadPlaceholder.ends(on: event) {
            reloading[tab.tabID] = nil
            updatePlaceholder(ended: Self.describe(event))
        }
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        updatePlaceholder(ended: "switch")
    }

    /// Forgets unloaded tabs whose row left the sidebar.
    func storeChanged(_ graph: SidebarGraph) {
        unloadedItems = unloadedItems.filter { graph[$0.key] != nil }
    }

    /// Shows the placeholder over the page area while the one tab it shows is loading again after an unload, and
    /// takes it away otherwise; `ended` says why, for the e2e log.
    private func updatePlaceholder(ended reason: String) {
        guard let window else { return }
        let shown = window.shownTabs
        let target = shown.first.flatMap { tab in reloading[tab.tabID].map { (tab, $0) } }
        if let (tab, entry) = target, UnloadPlaceholder.shows(wasUnloaded: true, paneCount: shown.count) {
            if placeholder?.tab == tab.tabID { return }
            removePlaceholder(reason: reason)
            let view = UnloadPlaceholderView(title: entry.card.title, host: entry.card.host, icon: entry.card.icon)
            window.addPageOverlay(view)
            placeholder = (tab.tabID, entry.item, view)
            #if BOW_E2E  // E2E seam: the unload tests read when the placeholder came and went.
                e2ePlaceholderLog.append("shown \(entry.item.rawValue)")
            #endif
        } else {
            removePlaceholder(reason: reason)
        }
    }

    private func removePlaceholder(reason: String) {
        guard let placeholder else { return }
        placeholder.view.removeFromSuperview()
        self.placeholder = nil
        #if BOW_E2E  // E2E seam
            e2ePlaceholderLog.append("hidden \(placeholder.item.rawValue) \(reason)")
        #endif
    }

    private static func describe(_ event: TabEvent) -> String {
        switch event {
        case .didFinish: "finish"
        case .didFail: "fail"
        case .renderProcessGone: "gone"
        case .unloaded: "unload"
        case .closed: "close"
        default: "other"
        }
    }

    #if BOW_E2E  // E2E seam: what the unload tests read of the placeholder.
        /// Each time the placeholder came ("shown <item>") and went ("hidden <item> <why>"), oldest first.
        private(set) var e2ePlaceholderLog: [String] = []
        /// The placeholder on screen: its sidebar item and the title it shows, nil when none is up.
        var e2ePlaceholder: (item: String, title: String, inWindow: Bool)? {
            placeholder.map { ($0.item.rawValue, $0.view.titleLabel.stringValue, $0.view.window != nil) }
        }
    #endif

    /// Notes a key that enters or edits text in a page's field; the page still gets it.
    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        if Self.editsText(event) { typedInto.insert(tab.tabID) }
        return false
    }

    /// Whether `event` types into an editable field: a key down or character with text, not another app shortcut
    /// (Command or Control held) than paste, cut or undo, and not a key that only moves (Tab, Escape, the arrow and
    /// function keys, which macOS reports as characters in the private use range, where Forward Delete edits).
    static func editsText(_ event: EngineKeyEvent) -> Bool {
        guard event.kind != .keyUp, event.isInEditableField, !event.modifiers.contains(.control) else { return false }
        if event.modifiers.contains(.command) {
            return ["v", "x", "z"].contains(event.charactersIgnoringModifiers.lowercased())
        }
        let moves: Set<UInt32> = [0x09, 0x19, 0x1B]
        let forwardDelete: UInt32 = 0xF728
        return event.characters.unicodeScalars.contains {
            $0.value == forwardDelete || (!moves.contains($0.value) && !(0xF700...0xF8FF).contains($0.value))
        }
    }

    /// The window's loaded tabs the unloader may consider now (see the type's notes for those never offered).
    func unloadCandidates() -> [Candidate] {
        guard let window, Self.isIdle(window) else { return [] }
        let graph = window.store.graph
        let shown = window.shownTabs
        let dialogs = window.feature(PageDialogsFeature.self)
        var busyProfiles: [ProfileID: Bool] = [:]
        var result: [Candidate] = []
        for entry in loaded.values {
            let tab = entry.tab
            guard !tab.isClosed, window.modelID(of: tab) != nil, let item = graph[entry.item], !tab.state.isLoading,
                !typedInto.contains(tab.tabID), dialogs?.hasDialog(for: tab) != true
            else { continue }
            let returnsToSaved = graph.isPinned(entry.item) || graph.isInFavorites(entry.item)
            if returnsToSaved, item.tab?.hasNavigatedAway(from: tab.state.url) == true { continue }
            let downloading =
                busyProfiles[tab.profileID]
                ?? (window.engineProfile(of: tab)?.downloads.items.contains { !$0.state.isFinal } ?? true)
            busyProfiles[tab.profileID] = downloading
            if downloading { continue }
            let state = tab.state
            let lastActive = max(activity.lastActive(entry.item) ?? .distantPast, entry.loadedAt)
            let unloadTab = UnloadTab(
                id: entry.id, lastActive: lastActive,
                isPinnedOrFavorite: returnsToSaved,
                isAudible: state.isAudible, lastAudibleAt: lastAudible[tab.tabID],
                isCapturing: state.isCapturingVideo || state.isCapturingAudio,
                isVisible: shown.contains { $0 === tab })
            result.append(Candidate(tab: tab, unloadTab: unloadTab))
        }
        return result
    }

    /// Unloads `tab` through the engine, which runs its beforeunload handler without a prompt and keeps a page that
    /// would ask to stay. Returns whether it was unloaded.
    func unload(_ tab: any EngineTab) async -> Bool {
        guard let window, Self.isIdle(window), window.modelID(of: tab) != nil,
            !window.shownTabs.contains(where: { $0 === tab })
        else {
            return false
        }
        // The card is read now, while the row still has the page's title and icon, and kept once the engine reports
        // the unload (before the window could load the tab again).
        if let item = loaded[tab.tabID]?.item {
            let sidebar = window.feature(SidebarFeature.self)
            let url = tab.state.url ?? sidebar?.shownTab(for: item)?.url
            let title = tab.state.title.isEmpty ? sidebar?.shownTab(for: item)?.title : tab.state.title
            unloading[tab.tabID] = (
                item,
                Card(
                    title: UnloadPlaceholder.title(saved: title, url: url), host: url?.host() ?? "",
                    icon: sidebar?.favicon(for: item))
            )
        }
        defer { unloading[tab.tabID] = nil }
        return await tab.unload()
    }

    /// The window is neither closing nor showing a sheet, and the app shows no modal panel, so the window's tabs may
    /// be unloaded.
    private static func isIdle(_ window: BrowserWindowController) -> Bool {
        !window.isClosing && window.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
}
