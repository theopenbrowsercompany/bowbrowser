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
    private func makeTab() -> (MockEngine, MockTab, TabList, BrowserTabID) {
        let engine = MockEngine()
        let engineTab = engine.defaultProfile.createTab(url: pageA) as! MockTab
        var list = TabList()
        let id = list.open()!
        return (engine, engineTab, list, id)
    }

    private func controls(_ list: TabList) -> NavigationControls {
        NavigationControls(activeTab: list.activeTab)
    }

    @Test func freshTabCanOnlyReload() {
        let (_, engineTab, list, id) = makeTab()
        var updated = list
        updated.update(id, from: engineTab.state)
        #expect(
            controls(updated)
                == NavigationControls(canGoBack: false, canGoForward: false, canReload: true, isLoading: false))
    }

    @Test func backFollowsTheTabsHistory() {
        var (_, engineTab, list, id) = makeTab()
        engineTab.simulateLoad(EngineNavigation(url: pageA))
        list.update(id, from: engineTab.state)
        #expect(!controls(list).canGoBack)
        engineTab.simulateLoad(EngineNavigation(url: pageB))
        list.update(id, from: engineTab.state)
        #expect(controls(list).canGoBack)
        #expect(!controls(list).canGoForward)
    }

    @Test func forwardFollowsTheTabsHistory() {
        var (_, engineTab, list, id) = makeTab()
        engineTab.push {
            $0.url = pageA
            $0.canGoForward = true
        }
        list.update(id, from: engineTab.state)
        #expect(controls(list).canGoForward)
        #expect(!controls(list).canGoBack)
    }

    @Test func loadingOffersStopAndStillReload() {
        var (_, engineTab, list, id) = makeTab()
        engineTab.push { $0.isLoading = true }
        list.update(id, from: engineTab.state)
        #expect(controls(list).canStop)
        #expect(controls(list).canReload)
        engineTab.push { $0.isLoading = false }
        list.update(id, from: engineTab.state)
        #expect(!controls(list).canStop)
        #expect(controls(list).canReload)
    }

    @Test func backgroundTabStateLeavesActiveControlsAlone() {
        var (_, engineTab, list, active) = makeTab()
        let background = list.open(activate: false)!
        engineTab.push {
            $0.isLoading = true
            $0.canGoBack = true
        }
        list.update(background, from: engineTab.state)
        #expect(list.activeID == active)
        #expect(
            controls(list)
                == NavigationControls(canGoBack: false, canGoForward: false, canReload: true, isLoading: false))
    }

    @Test func noActiveTabOffersNothing() {
        var (_, _, list, id) = makeTab()
        list.close(id)
        #expect(controls(list) == .disabled)
        #expect(!NavigationControls.disabled.canStop)
    }
}
