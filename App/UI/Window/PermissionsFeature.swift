import AppKit
import BowCore

/// Site permission prompts: answers the window's permission requests from the remembered answers of the asking tab's
/// own profile, or by asking in a prompt anchored to the page (`PermissionPrompts`). The prompt follows the tab on
/// screen. Each request looks its profile up through the window's profile resolver, so a tab in a Space on another
/// profile reads and writes that profile's answers, not those of the Space on screen when the window opened.
@MainActor
final class PermissionsFeature: NSResponder, BrowserWindowFeature {
    /// The window's permission prompts, anchored to the web view, the page area to the right of the sidebar. A tab
    /// whose profile the engine does not know has its requests dismissed.
    let prompts: PermissionPrompts

    init(window: BrowserWindowController) {
        let stores = window.appFeatures.require(SitePermissionStores.self)
        prompts = PermissionPrompts(hostView: window.webView) { [unowned window] tab in
            guard let profile = window.engineProfile(of: tab) else { return nil }
            return PermissionPrompts.ProfilePermissions(store: stores.store(for: profile), profile: profile)
        }
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        // Another tab shows its own waiting request, or none.
        prompts.show(tab)
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        // A prompt belongs to the page that asked; a new page asks again if it needs to.
        if case .didCommit = event { prompts.dismissRequests(of: tab) }
    }

    func tabDidClose(_ tab: any EngineTab) {
        prompts.dismissRequests(of: tab)
    }

    func decidePermission(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision? {
        await prompts.decide(request, for: tab)
    }
}
