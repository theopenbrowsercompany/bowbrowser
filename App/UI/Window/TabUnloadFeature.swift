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
/// spares tabs using the camera or microphone and tabs playing sound (CEF 156 reports no audible state, so that
/// exemption never applies yet).
@MainActor
final class TabUnloadFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?
    private let unloader: TabUnloader
    private let activity: TabActivityLog
    private var loaded: [TabID: Entry] = [:]
    /// Pages the person typed into, until their next main frame commit.
    private var typedInto: Set<TabID> = []

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
        typedInto.remove(tab.tabID)
    }

    /// A new page committed: what was typed into the old one went with it.
    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        if case .didCommit = event { typedInto.remove(tab.tabID) }
    }

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
                isAudible: state.isAudible, isCapturing: state.isCapturingVideo || state.isCapturingAudio,
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
        return await tab.unload()
    }

    /// The window is neither closing nor showing a sheet, and the app shows no modal panel, so the window's tabs may
    /// be unloaded.
    private static func isIdle(_ window: BrowserWindowController) -> Bool {
        !window.isClosing && window.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
}
