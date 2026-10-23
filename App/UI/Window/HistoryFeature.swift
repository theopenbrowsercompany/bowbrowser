import AppKit
import BowCore

/// Feeds the app's history from a window's tabs: each tab's events go to the history of the tab's own profile, so a
/// committed navigation records a visit and a later title update names it.
@MainActor
final class HistoryFeature: NSResponder, BrowserWindowFeature {
    private let stores: HistoryStores

    init(window: BrowserWindowController) {
        stores = window.appFeatures.require(HistoryStores.self)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .didCommit, .stateChanged: break
        default: return
        }
        let profileID = tab.profileID
        // The engine's profile says whether it is persistent; one the engine does not have records in memory only.
        let engine = (NSApp.delegate as? AppDelegate)?.engine
        guard
            let store = stores.store(
                for: profileID, isPersistent: engine?.profile(id: profileID)?.isPersistent ?? false)
        else { return }
        do {
            try store.handle(event)
        } catch {
            FileHandle.standardError.write(Data("bow: recording history failed: \(error)\n".utf8))
        }
    }
}
