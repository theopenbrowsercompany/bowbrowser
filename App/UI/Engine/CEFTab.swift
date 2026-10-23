import AppKit
import BowCore

/// One bridge tab as an `EngineTab`. The adapter is both of the bridge tab's delegates (navigation and UI) and
/// merges what they report into `TabEvent` values for its one `EngineTabDelegate`. Whoever holds the adapter keeps
/// receiving events; the page itself lives until it closes, held or not.
///
/// JavaScript dialogs and context menus need answers the BowCore contract has no API for yet, so the adapter leaves
/// those UI delegate methods out and the engine handles them its own way (its own dialogs, the tab's own "leave
/// this site?" sheet, its own context menu). Permission requests go to the delegate's `decidePermission`.
@MainActor
final class CEFTab: NSObject, EngineTab {
    /// Read only by the host view seam below, never by app logic.
    let tab: BowTab

    let tabID: TabID
    let profileID: ProfileID
    weak var delegate: (any EngineTabDelegate)?

    init(_ tab: BowTab) {
        self.tab = tab
        tabID = TabID(rawValue: tab.tabID)
        profileID = ProfileID(tab.profileID)
        super.init()
        // The bridge tab holds both weakly; whoever holds this adapter keeps them alive.
        tab.navigationDelegate = self
        tab.uiDelegate = self
    }

    var state: EngineTabState { EngineTabState(tab.state) }
    var isClosed: Bool { tab.isClosed }

    func load(_ url: URL) { tab.load(url) }
    func goBack() { tab.goBack() }
    func goForward() { tab.goForward() }
    func reload() { tab.reload() }
    func stop() { tab.stop() }
    func find(_ text: String, forward: Bool, matchCase: Bool) { tab.find(text, forward: forward, matchCase: matchCase) }
    func stopFind() { tab.stopFind() }

    func close() async -> Bool {
        await withCheckedContinuation { continuation in
            tab.close { closed in
                continuation.resume(returning: closed)
            }
        }
    }

    func unload() async -> Bool {
        await withCheckedContinuation { continuation in
            tab.unload { unloaded in
                continuation.resume(returning: unloaded)
            }
        }
    }

    var zoomLevel: Double { tab.zoomLevel }
    func setZoomLevel(_ level: Double) { tab.zoomLevel = level }

    func send(_ event: TabEvent) {
        delegate?.tab(self, didReceive: event)
    }
}
