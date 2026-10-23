/// Tells a page that closed itself apart from one the engine never managed to create. Both close with
/// `TabCloseReason.page`, but only a page that committed a document can call `window.close()`, so a tab that closes
/// for that reason before any commit was never a page: a window keeps its sidebar row and saved page, rather than
/// deleting a saved tab the person did not close.
public struct SelfClosedPages: Sendable {
    private var committed: Set<TabID> = []

    public init() {}

    /// Notes an event of tab `tabID`; a committed navigation means the tab has a page that could close itself.
    public mutating func record(_ event: TabEvent, of tabID: TabID) {
        if case .didCommit = event { committed.insert(tabID) }
    }

    /// Whether `tab`, which has just closed, closed itself: closed by the engine for `.page` after a page committed.
    /// Forgets the tab, so call it once, when its `closed` event arrives.
    @MainActor public mutating func closedItself(_ tab: any EngineTab) -> Bool {
        let hadPage = committed.remove(tab.tabID) != nil
        return hadPage && tab.closeReason == .page
    }
}
