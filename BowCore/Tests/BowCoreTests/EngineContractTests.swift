import BowCore
import BowCoreTestSupport
import Foundation
import Testing

@MainActor @Suite struct EngineContractTests {
    let example = URL(string: "https://example.com/")!
    let docs = URL(string: "https://example.com/docs")!

    @Test func defaultProfileAlwaysExistsAndIsPersistent() throws {
        let engine: any BrowserEngine = MockEngine()
        let profile = try #require(engine.profile(id: .default))
        #expect(profile.profileID == ProfileID("Default"))
        #expect(profile.isPersistent)
    }

    @Test func createsAndLooksUpProfilesByID() throws {
        let mock = MockEngine()
        let engine: any BrowserEngine = mock
        let work = try engine.createProfile(id: "work", isPersistent: true)
        let privateProfile = try engine.createProfile(id: "private", isPersistent: false)

        #expect(engine.profile(id: "work") === work)
        #expect(engine.profile(id: "private") === privateProfile)
        #expect(!privateProfile.isPersistent)
        #expect(engine.profile(id: "missing") == nil)
        #expect(throws: EngineError.profileExists("work")) {
            try engine.createProfile(id: "work", isPersistent: false)
        }
        #expect(
            mock.calls == [
                .createProfile("work", isPersistent: true),
                .createProfile("private", isPersistent: false),
                .createProfile("work", isPersistent: false),
            ])
    }

    @Test func assignsUniqueTabIDsAcrossProfilesAtCreation() throws {
        let engine = MockEngine()
        let work = try engine.createProfile(id: "work", isPersistent: true)
        let first = engine.defaultProfile.createTab(url: example)
        let second = work.createTab(url: docs)

        #expect(first.tabID != second.tabID)
        #expect(first.state.tabID == first.tabID)
        #expect(second.profileID == "work")
        #expect(first.state.url == nil)
        #expect(engine.openTabs.map(\.tabID) == [first.tabID, second.tabID])
        #expect(engine.openTabs.last?.initialURL == docs)
    }

    @Test func recordsNavigationCommands() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        tab.load(docs)
        tab.goBack()
        tab.goForward()
        tab.reload()
        tab.stop()

        let mock = engine.openTabs[0]
        #expect(mock.calls == [.load(docs), .goBack, .goForward, .reload, .stop])
    }

    @Test func deliversLoadEventsInOrderAndUpdatesState() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        let mock = engine.openTabs[0]
        let navigation = EngineNavigation(url: example, transition: .typed)

        mock.simulateLoad(navigation, title: "Example")

        let id = tab.tabID
        let loading = EngineTabState(tabID: id, isLoading: true)
        let committed = EngineTabState(tabID: id, url: example, title: "Example", isLoading: true)
        let idle = EngineTabState(tabID: id, url: example, title: "Example")
        #expect(delegate.policyRequests == [navigation])
        #expect(
            delegate.events == [
                .didStartNavigation(navigation),
                .stateChanged(loading),
                .didCommit(navigation),
                .stateChanged(committed),
                .didFinish(navigation, httpStatus: 200),
                .stateChanged(idle),
            ])
        #expect(tab.state == idle)
    }

    @Test func secondLoadEnablesBack() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let mock = engine.openTabs[0]
        mock.simulateLoad(EngineNavigation(url: example))
        #expect(!tab.state.canGoBack)
        mock.simulateLoad(EngineNavigation(url: docs, transition: .link, isUserGesture: true))
        #expect(tab.state.canGoBack)
        #expect(!tab.state.canGoForward)
        #expect(tab.state.url == docs)
    }

    @Test func cancelledPolicyStopsTheNavigation() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let delegate = RecordingTabDelegate()
        delegate.policy = { $0.url.host == "blocked.example" ? .cancel : .allow }
        tab.delegate = delegate
        let blocked = EngineNavigation(url: URL(string: "https://blocked.example/")!, transition: .link)

        let policy = engine.openTabs[0].simulateLoad(blocked)

        #expect(policy == .cancel)
        #expect(delegate.events.isEmpty)
        #expect(tab.state.url == nil)
    }

    @Test func failedLoadReportsTheError() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        let navigation = EngineNavigation(url: example)
        let error = NavigationError(code: -105, description: "ERR_NAME_NOT_RESOLVED")

        engine.openTabs[0].simulateFailedLoad(navigation, error: error)

        #expect(delegate.events.contains(.didFail(navigation, error)))
        #expect(!tab.state.isLoading)
    }

    @Test func deliversPopupAndProcessGoneEvents() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        let mock = engine.openTabs[0]
        let popup = PopupRequest(
            targetURL: docs, disposition: .popup, isUserGesture: true, requestedSize: PopupSize(width: 500, height: 600)
        )

        mock.emit(.popupRequested(popup))
        mock.emit(.renderProcessGone(.crashed))

        #expect(delegate.events == [.popupRequested(popup), .renderProcessGone(.crashed)])
    }

    @Test func closeHonorsBeforeUnload() async {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let mock = engine.openTabs[0]

        mock.beforeUnloadCancelsClose = true
        #expect(await tab.close() == false)
        #expect(!mock.isClosed)

        mock.beforeUnloadCancelsClose = false
        #expect(await tab.close() == true)
        #expect(mock.isClosed)
        #expect(mock.calls == [.close, .close])
        #expect(engine.openTabs.isEmpty)
    }

    @Test func quitClosesEveryTab() async throws {
        let engine = MockEngine()
        let work = try engine.createProfile(id: "work", isPersistent: true)
        _ = engine.defaultProfile.createTab(url: example)
        _ = work.createTab(url: docs)
        engine.openTabs[0].beforeUnloadCancelsClose = true

        await engine.quit()

        #expect(engine.hasQuit)
        #expect(engine.openTabs.isEmpty)
        #expect(engine.calls.last == .quit)
    }

    @Test func delegateIsHeldWeakly() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        do {
            let delegate = RecordingTabDelegate()
            tab.delegate = delegate
            #expect(tab.delegate != nil)
        }
        #expect(tab.delegate == nil)
    }
}
