import BowCore
import BowCoreTestSupport
import Foundation
import Testing

@MainActor @Suite struct NavigationControlsTests {
    let pageA = URL(string: "https://example.com/a")!
    let pageB = URL(string: "https://example.com/b")!

    @Test func freshTabCanOnlyReload() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: pageA)
        let controls = NavigationControls(state: tab.state, isClosed: tab.isClosed)
        #expect(controls == NavigationControls(canGoBack: false, canGoForward: false, canReload: true, isLoading: false))
        #expect(!controls.canStop)
    }

    @Test func backFollowsCanGoBack() {
        var state = EngineTabState(tabID: 1, url: pageB)
        #expect(!NavigationControls(state: state, isClosed: false).canGoBack)
        state.canGoBack = true
        #expect(NavigationControls(state: state, isClosed: false).canGoBack)
    }

    @Test func forwardFollowsCanGoForward() {
        var state = EngineTabState(tabID: 1, url: pageA)
        #expect(!NavigationControls(state: state, isClosed: false).canGoForward)
        state.canGoForward = true
        #expect(NavigationControls(state: state, isClosed: false).canGoForward)
    }

    @Test func loadingOffersStopAndStillReload() {
        let state = EngineTabState(tabID: 1, url: pageA, isLoading: true)
        let controls = NavigationControls(state: state, isClosed: false)
        #expect(controls.isLoading)
        #expect(controls.canStop)
        #expect(controls.canReload)
    }

    @Test func closedTabOffersNothing() {
        let state = EngineTabState(tabID: 1, url: pageA, isLoading: true, canGoBack: true, canGoForward: true)
        #expect(NavigationControls(state: state, isClosed: true) == .disabled)
        #expect(!NavigationControls.disabled.canStop)
    }
}
