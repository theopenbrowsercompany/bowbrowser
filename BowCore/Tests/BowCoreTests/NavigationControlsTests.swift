import BowCore
import BowCoreTestSupport
import Foundation
import Testing

/// The navigation rules, each checked through the tab model: the engine's pushed state is applied to the tab list,
/// and the controls are read from its active tab.
@MainActor @Suite struct NavigationControlsTests {
    let pageA = URL(string: "https://example.com/a")!
    let pageB = URL(string: "https://example.com/b")!

    /// A list with one active tab, fed by a mock engine tab.
    @MainActor private struct Fixture {
        /// Kept so the mock tab's engine outlives the test.
        let engine = MockEngine()
        let engineTab: MockTab
        var list = TabList()
        let id: BrowserTabID

        init(url: URL) {
            engineTab = engine.defaultProfile.createTab(url: url) as! MockTab
            id = list.open()!
        }
    }

    private func makeTab() -> Fixture { Fixture(url: pageA) }

    private func controls(_ list: TabList) -> NavigationControls {
        NavigationControls(activeTab: list.activeTab)
    }

    @Test func freshTabCanOnlyReload() {
        var fixture = makeTab()
        let (engineTab, id) = (fixture.engineTab, fixture.id)
        fixture.list.update(id, from: engineTab.state)
        #expect(
            controls(fixture.list)
                == NavigationControls(canGoBack: false, canGoForward: false, canReload: true, isLoading: false))
    }

    @Test func backFollowsTheTabsHistory() {
        var fixture = makeTab()
        let (engineTab, id) = (fixture.engineTab, fixture.id)
        engineTab.simulateLoad(EngineNavigation(url: pageA))
        fixture.list.update(id, from: engineTab.state)
        #expect(!controls(fixture.list).canGoBack)
        engineTab.simulateLoad(EngineNavigation(url: pageB))
        fixture.list.update(id, from: engineTab.state)
        #expect(controls(fixture.list).canGoBack)
        #expect(!controls(fixture.list).canGoForward)
    }

    @Test func forwardFollowsTheTabsHistory() {
        var fixture = makeTab()
        let (engineTab, id) = (fixture.engineTab, fixture.id)
        engineTab.push {
            $0.url = pageA
            $0.canGoForward = true
        }
        fixture.list.update(id, from: engineTab.state)
        #expect(controls(fixture.list).canGoForward)
        #expect(!controls(fixture.list).canGoBack)
    }

    @Test func loadingOffersStopAndStillReload() {
        var fixture = makeTab()
        let (engineTab, id) = (fixture.engineTab, fixture.id)
        engineTab.push { $0.isLoading = true }
        fixture.list.update(id, from: engineTab.state)
        #expect(controls(fixture.list).canStop)
        #expect(controls(fixture.list).canReload)
        engineTab.push { $0.isLoading = false }
        fixture.list.update(id, from: engineTab.state)
        #expect(!controls(fixture.list).canStop)
        #expect(controls(fixture.list).canReload)
    }

    @Test func backgroundTabStateLeavesActiveControlsAlone() {
        var fixture = makeTab()
        let (engineTab, active) = (fixture.engineTab, fixture.id)
        let background = fixture.list.open(activate: false)!
        engineTab.push {
            $0.isLoading = true
            $0.canGoBack = true
        }
        fixture.list.update(background, from: engineTab.state)
        #expect(fixture.list.activeID == active)
        #expect(
            controls(fixture.list)
                == NavigationControls(canGoBack: false, canGoForward: false, canReload: true, isLoading: false))
    }

    @Test func noActiveTabOffersNothing() {
        var fixture = makeTab()
        let id = fixture.id
        fixture.list.close(id)
        #expect(controls(fixture.list) == .disabled)
        #expect(!NavigationControls.disabled.canStop)
    }
}
