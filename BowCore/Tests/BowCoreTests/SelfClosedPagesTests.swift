import BowCore
import BowCoreTestSupport
import Foundation
import Testing

@MainActor @Suite struct SelfClosedPagesTests {
    let example = URL(string: "https://example.com/")!

    /// Records every event of its tabs, as a window does.
    final class Recorder: EngineTabDelegate {
        var pages = SelfClosedPages()
        var closedItself: Bool?

        func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
            pages.record(event, of: tab.tabID)
            if event == .closed { closedItself = pages.closedItself(tab) }
        }
    }

    @Test func pageThatCommittedThenClosedItselfClosedItself() {
        let engine = MockEngine()
        let recorder = Recorder()
        let tab = engine.defaultProfile.createTab(url: example)
        tab.delegate = recorder
        let mock = engine.openTabs[0]
        _ = mock.simulateLoad(EngineNavigation(url: example))
        mock.markClosed(reason: .page)
        #expect(recorder.closedItself == true)
    }

    @Test func pageTheEngineCouldNotCreateDidNotCloseItself() {
        let engine = MockEngine()
        let recorder = Recorder()
        let tab = engine.defaultProfile.createTab(url: example)
        tab.delegate = recorder
        engine.openTabs[0].markClosed(reason: .page)
        #expect(recorder.closedItself == false)
    }

    @Test func appOrQuitCloseIsNotThePagesOwn() async {
        let engine = MockEngine()
        let recorder = Recorder()
        let first = engine.defaultProfile.createTab(url: example)
        first.delegate = recorder
        _ = engine.openTabs[0].simulateLoad(EngineNavigation(url: example))
        _ = await first.close()
        #expect(recorder.closedItself == false)

        let second = engine.defaultProfile.createTab(url: example)
        second.delegate = recorder
        _ = engine.openTabs[0].simulateLoad(EngineNavigation(url: example))
        await engine.quit()
        #expect(recorder.closedItself == false)
    }
}
