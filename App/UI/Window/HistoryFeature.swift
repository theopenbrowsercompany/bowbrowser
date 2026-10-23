import AppKit
import BowCore

/// Feeds the app's history from a window's tabs: each tab's events go to the history of the tab's own profile, so a
/// committed navigation records a visit and a later title update names it.
@MainActor
final class HistoryFeature: NSResponder, BrowserWindowFeature {
    private let stores: HistoryStores
    private weak var window: BrowserWindowController?
    /// The URL and title last recorded from each tab's state, so a state change that repeats them writes nothing.
    private var lastState: [TabID: String] = [:]

    init(window: BrowserWindowController) {
        self.window = window
        stores = window.appFeatures.require(HistoryStores.self)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .didCommit:
            lastState[tab.tabID] = nil
        case .stateChanged(let state):
            // Loading and progress changes come often; only a new URL or title can change history.
            let key = "\(state.url?.absoluteString ?? "")\n\(state.title)"
            guard lastState[tab.tabID] != key else { return }
            lastState[tab.tabID] = key
        default:
            return
        }
        let profileID = tab.profileID
        guard let store = stores.store(for: profileID, isPersistent: { isPersistent(profileID) }) else { return }
        do {
            try store.handle(event)
        } catch {
            FileHandle.standardError.write(Data("bow: recording history failed: \(error)\n".utf8))
        }
    }

    func tabDidClose(_ tab: any EngineTab) {
        lastState[tab.tabID] = nil
    }

    /// Whether the engine's profile `profileID` keeps its data on disk: asked of the window's own profile first,
    /// then of the engine. Nil when neither knows the profile.
    private func isPersistent(_ profileID: ProfileID) -> Bool? {
        if let active = window?.activeProfile, active.profileID == profileID { return active.isPersistent }
        return (NSApp.delegate as? AppDelegate)?.engine.profile(id: profileID)?.isPersistent
    }
}
