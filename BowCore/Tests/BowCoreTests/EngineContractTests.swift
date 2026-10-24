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
        let error = NavigationError(reason: .nameNotResolved, description: "the name did not resolve")

        engine.openTabs[0].simulateFailedLoad(navigation, error: error)

        #expect(delegate.events.contains(.didFail(navigation, error)))
        #expect(!tab.state.isLoading)
        #expect(!error.isAborted)
    }

    @Test func onlyTheAbortedReasonCountsAsAborted() {
        for reason in NavigationError.Reason.allCases {
            let error = NavigationError(reason: reason, description: "")
            #expect(error.isAborted == (reason == .aborted), "\(reason)")
        }
        // The engine's text is kept for logs but never decides anything.
        #expect(
            NavigationError(reason: .cannotConnect, description: "a")
                != NavigationError(reason: .cannotConnect, description: "b"))
        #expect(!NavigationError(reason: .other, description: "aborted").isAborted)
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
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate

        mock.beforeUnloadCancelsClose = true
        #expect(await tab.close() == false)
        #expect(!tab.isClosed)
        #expect(delegate.events.isEmpty)

        mock.beforeUnloadCancelsClose = false
        #expect(await tab.close() == true)
        #expect(tab.isClosed)
        #expect(await tab.close() == true)
        #expect(mock.calls == [.close, .close, .close])
        #expect(engine.openTabs.isEmpty)
        #expect(delegate.events == [.closed])
        #expect(tab.closeReason == .app)
    }

    @Test func pageClosingItselfSendsClosed() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate

        let mock = engine.openTabs[0]
        mock.markClosed()
        mock.markClosed()

        #expect(tab.isClosed)
        #expect(delegate.events == [.closed])
        #expect(tab.closeReason == .page)
    }

    @Test func quitClosesEveryTab() async throws {
        let engine = MockEngine()
        let work = try engine.createProfile(id: "work", isPersistent: true)
        let first = engine.defaultProfile.createTab(url: example)
        let second = work.createTab(url: docs)
        let delegate = RecordingTabDelegate()
        first.delegate = delegate
        second.delegate = delegate
        engine.openTabs[0].beforeUnloadCancelsClose = true

        await engine.quit()

        #expect(engine.hasQuit)
        #expect(engine.openTabs.isEmpty)
        #expect(first.isClosed && second.isClosed)
        #expect(delegate.events == [.closed, .closed])
        #expect(first.closeReason == .quit && second.closeReason == .quit)
        #expect(engine.calls.last == .quit)
    }

    @Test func refusesInvalidAndTakenProfileIDs() throws {
        let engine: any BrowserEngine = MockEngine()
        _ = try engine.createProfile(id: "work-1.a_b", isPersistent: true)

        for id: ProfileID in ["", ".", "..", "a/b", "spaced id", "caf\u{E9}"] {
            #expect(!id.isValid)
            #expect(throws: EngineError.invalidProfileID(id)) {
                try engine.createProfile(id: id, isPersistent: false)
            }
        }
        for id: ProfileID in ["default", "WORK-1.A_B"] {
            #expect(throws: EngineError.profileExists(id)) {
                try engine.createProfile(id: id, isPersistent: false)
            }
        }
        #expect(ProfileID("...").isValid)
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
