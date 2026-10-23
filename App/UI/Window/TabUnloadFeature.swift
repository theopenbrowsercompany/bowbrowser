import AppKit
import BowCore

/// Lists a window's loaded tabs, in every Space, for the app's `TabUnloader`, and unloads the ones it picks.
///
/// Never offered: the tab the window shows, every tab while the window closes, shows a sheet (a leave prompt) or the
/// app shows a modal panel (a page's alert, even from a background tab), which an unload would take away unanswered
/// (the next pass tries again), a tab whose row left the sidebar,
/// a tab still loading (a navigation under way), and every tab of a profile with a download under way, since the
/// engine cannot tell which page a download came from and destroying that page would cancel it. The policy itself
/// spares tabs using the camera or microphone and tabs playing sound (CEF 156 reports no audible state, so that
/// exemption never applies yet).
@MainActor
final class TabUnloadFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?
    private let unloader: TabUnloader
    private let activity: TabActivityLog
    private var loaded: [TabID: Entry] = [:]

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
    }

    func tabDidClose(_ tab: any EngineTab) {
        loaded[tab.tabID] = nil
    }

    /// The window's loaded tabs the unloader may consider now (see the type's notes for those never offered).
    func unloadCandidates() -> [Candidate] {
        guard let window, Self.isIdle(window) else { return [] }
        let graph = window.store.graph
        let shown = window.selectedTab
        var busyProfiles: [ProfileID: Bool] = [:]
        var result: [Candidate] = []
        for entry in loaded.values {
            let tab = entry.tab
            guard !tab.isClosed, window.modelID(of: tab) != nil, graph[entry.item] != nil, !tab.state.isLoading
            else { continue }
            let downloading =
                busyProfiles[tab.profileID]
                ?? (window.engineProfile(of: tab)?.downloads.items.contains { !$0.state.isFinal } ?? true)
            busyProfiles[tab.profileID] = downloading
            if downloading { continue }
            let state = tab.state
            let lastActive = max(activity.lastActive(entry.item) ?? .distantPast, entry.loadedAt)
            let unloadTab = UnloadTab(
                id: entry.id, lastActive: lastActive,
                isPinnedOrFavorite: graph.isPinned(entry.item) || graph.isInFavorites(entry.item),
                isAudible: state.isAudible, isCapturing: state.isCapturingVideo || state.isCapturingAudio,
                isVisible: shown === tab)
            result.append(Candidate(tab: tab, unloadTab: unloadTab))
        }
        return result
    }

    /// Unloads `tab` through the engine, which runs its beforeunload handler without a prompt and keeps a page that
    /// would ask to stay. Returns whether it was unloaded.
    func unload(_ tab: any EngineTab) async -> Bool {
        guard let window, Self.isIdle(window), window.modelID(of: tab) != nil, window.selectedTab !== tab else {
            return false
        }
        return await tab.unload()
    }

    /// The window is neither closing nor showing a sheet, and the app shows no modal panel (the engine shows a page's
    /// alert as one, even from a background tab), so the window's tabs may be unloaded.
    private static func isIdle(_ window: BrowserWindowController) -> Bool {
        !window.isClosing && window.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
}
