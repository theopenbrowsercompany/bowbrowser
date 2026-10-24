import BowCore
import Foundation

extension WebKitProfile {
    /// A tab on a fresh web view of this profile that takes the session an unloaded tab kept
    /// (`WebKitTab.sessionState`) before any load, so it comes back on the entry it was on with its back and forward
    /// history and scroll positions. With no state, or state WebKit cannot read, it loads `url` as `createTab(url:)`
    /// does.
    func createTab(url: URL, restoring sessionState: Data?) -> any EngineTab {
        let tab = WebKitTab(profile: self)
        if let sessionState, tab.restore(sessionState) { return tab }
        tab.load(url)
        return tab
    }
}
