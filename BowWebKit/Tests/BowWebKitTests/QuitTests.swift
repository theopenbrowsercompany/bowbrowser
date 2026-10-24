import BowCore
import Foundation
import Testing

@testable import BowWebKit

/// Quitting closes every tab however it was made, with `TabCloseReason.quit`; a profile that is quitting refuses new
/// tabs; and the engine's optional protocol requirements reach their WebKit witnesses through the protocols.
@Suite(.serialized) @MainActor struct QuitTests {
    init() {
        TestHost.start()
    }

    @Test func quitClosesARestoredTabWithQuitAndAPlainCloseStaysApp() async throws {
        try await withEngine(TestStores()) { rig in
            let main = try #require(rig.engine.profile(id: .default) as? WebKitProfile)
            let start = rig.server.url("/navigation/start.html")
            let source = rig.tab(in: main, "/navigation/start.html")
            try await waitUntil("the source tab loaded start; title \(source.state.title)") {
                source.state.title == "Navigation start" && !source.state.isLoading
            }
            #expect(await source.unload())
            let state = try #require(source.sessionState)

            let restored = try #require(main.createTab(url: start, restoring: state) as? WebKitTab)
            let plain = rig.tab(in: main, "/navigation/a.html")
            let closedByApp = rig.tab(in: main, "/navigation/b.html")
            #expect(await closedByApp.close())
            #expect(closedByApp.closeReason == .app)
            #expect(main.openTabs.contains { $0 === restored } && main.openTabs.contains { $0 === plain })

            await rig.engine.quit()
            #expect(restored.isClosed && restored.closeReason == .quit && restored.webView == nil)
            #expect(plain.isClosed && plain.closeReason == .quit)
            #expect(closedByApp.closeReason == .app)
            #expect(main.openTabs.isEmpty)
        }
    }

    @Test func quitEndsWhenADelegateOpensATabOnEveryClose() async throws {
        try await withEngine(TestStores()) { rig in
            let main = try #require(rig.engine.profile(id: .default) as? WebKitProfile)
            let first = rig.tab(in: main, "/navigation/start.html")
            let reopener = ReopenForeverDelegate(profile: main, url: rig.server.url("/navigation/a.html"))
            first.delegate = reopener

            await rig.engine.quit()
            // The tab the delegate opened during the quit was refused: made already closed with .quit, never loaded.
            #expect(first.isClosed && first.closeReason == .quit)
            #expect(reopener.opened.count == 1)
            let refused = try #require(reopener.opened.first)
            #expect(refused.isClosed && refused.closeReason == .quit && refused.webView == nil)
            #expect(main.openTabs.isEmpty)

            // The profile goes on refusing: a tab made after the quit is closed at birth too, and so is one on a
            // profile made after it.
            let late = try #require(main.createTab(url: rig.server.url("/navigation/a.html")) as? WebKitTab)
            #expect(late.isClosed && late.closeReason == .quit && late.webView == nil)
            let after = try rig.engine.createProfile(
                ProfileRef(engineID: "After", storeID: UUID(), isPersistent: false))
            let afterTab = try #require(after.createTab(url: rig.server.url("/navigation/a.html")) as? WebKitTab)
            #expect(afterTab.isClosed && afterTab.closeReason == .quit)
        }
    }

    /// Called through `any EngineTab` and `any EngineProfile`, as the app calls them, so a protocol extension default
    /// cannot stand in for the WebKit witness.
    @Test func unloadSessionStateAndRestoreReachTheWitnessesThroughTheProtocols() async throws {
        try await withEngine(TestStores()) { rig in
            let profile: any EngineProfile = try #require(rig.engine.profile(id: .default))
            let start = rig.server.url("/navigation/start.html")
            let a = rig.server.url("/navigation/a.html")
            let tab: any EngineTab = rig.tab(in: profile, "/navigation/start.html")
            try await waitUntil("the tab loaded start; title \(tab.state.title)") {
                tab.state.title == "Navigation start" && !tab.state.isLoading
            }
            #expect(tab.sessionState == nil)
            #expect(await tab.unload())
            #expect(tab.sessionState != nil && tab.isClosed)

            // The session names start; the address given is a. Only the witness restores the session.
            let restored: any EngineTab = profile.createTab(url: a, restoring: tab.sessionState)
            try await waitUntil("the restored tab is on start; saw \(restored.state.url?.absoluteString ?? "nil")") {
                restored.state.url == start
            }
            #expect(restored.profileID == profile.profileID)
        }
    }
}

/// A tab delegate that answers every close with a new tab on `profile`, and hears the new tab's close in turn.
@MainActor
final class ReopenForeverDelegate: EngineTabDelegate {
    let profile: WebKitProfile
    let url: URL
    private(set) var opened: [WebKitTab] = []

    init(profile: WebKitProfile, url: URL) {
        self.profile = profile
        self.url = url
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        guard event == .closed, let next = profile.createTab(url: url) as? WebKitTab else { return }
        next.delegate = self
        opened.append(next)
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy { .allow }
}
