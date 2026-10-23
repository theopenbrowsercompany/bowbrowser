import AppKit
import BowCore

/// Site permission prompts: answers the window's permission requests from the profile's remembered answers, or by
/// asking in a prompt anchored to the page (`PermissionPrompts`). The prompt follows the tab on screen.
///
/// The prompts use the profile of the Space on screen when the window opens. Known limit: a window whose Spaces use
/// different profiles needs prompts per tab profile, which comes with profiles behind Spaces.
@MainActor
final class PermissionsFeature: NSResponder, BrowserWindowFeature {
    private unowned let window: BrowserWindowController
    /// The window's permission prompts, anchored to the web view, the page area to the right of the sidebar. Nil
    /// when the Space on screen has no engine profile, in which case every request is dismissed.
    let prompts: PermissionPrompts?

    init(window: BrowserWindowController) {
        self.window = window
        prompts = window.activeProfile.map { profile in
            let store = window.appFeatures.require(SitePermissionStores.self).store(for: profile)
            return PermissionPrompts(store: store, profile: profile, hostView: window.webView)
        }
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        // Another tab shows its own waiting request, or none.
        prompts?.show(tab)
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        // A prompt belongs to the page that asked; a new page asks again if it needs to.
        if case .didCommit = event { prompts?.dismissRequests(of: tab) }
    }

    func tabDidClose(_ tab: any EngineTab) {
        prompts?.dismissRequests(of: tab)
    }

    func decidePermission(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision? {
        await prompts?.decide(request, for: tab)
    }
}
