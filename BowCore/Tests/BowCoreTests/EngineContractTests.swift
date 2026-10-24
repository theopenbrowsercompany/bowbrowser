import BowCore
import BowCoreTestSupport
import Foundation
import Testing

@MainActor @Suite struct EngineContractTests {
    let example = URL(string: "https://example.com/")!
    let docs = URL(string: "https://example.com/docs")!
    let workStore = UUID(uuidString: "6B1E0A52-7C0D-4E0B-9F3A-2D8C5E4F1A01")!
    let privateStore = UUID(uuidString: "6B1E0A52-7C0D-4E0B-9F3A-2D8C5E4F1A02")!

    /// A ref for `id`, with a storage UUID of its own unless one is given.
    func ref(_ id: ProfileID, _ isPersistent: Bool, store: UUID = UUID()) -> ProfileRef {
        ProfileRef(engineID: id, storeID: store, isPersistent: isPersistent)
    }

    @Test func defaultProfileAlwaysExistsAndIsPersistent() throws {
        let engine: any BrowserEngine = MockEngine()
        let profile = try #require(engine.profile(id: .default))
        #expect(profile.profileID == ProfileID("Default"))
        #expect(profile.isPersistent)
    }

    @Test func createsAndLooksUpProfilesByID() throws {
        let mock = MockEngine()
        let engine: any BrowserEngine = mock
        let work = try engine.createProfile(ref("work", true, store: workStore))
        let privateProfile = try engine.createProfile(ref("private", false, store: privateStore))

        #expect(engine.profile(id: "work") === work)
        #expect(engine.profile(id: "private") === privateProfile)
        #expect(work.isPersistent)
        #expect(!privateProfile.isPersistent)
        #expect(engine.profile(id: "missing") == nil)
        #expect(throws: EngineError.profileExists("work")) {
            try engine.createProfile(ref("work", false, store: privateStore))
        }
        #expect(
            mock.calls == [
                .createProfile(ref("work", true, store: workStore)),
                .createProfile(ref("private", false, store: privateStore)),
                .createProfile(ref("work", false, store: privateStore)),
            ])
    }

    @Test func aRegistryRecordReachesTheEngineWithItsStorageUUID() throws {
        let mock = MockEngine()
        let engine: any BrowserEngine = mock
        let record = ProfileRecord(id: SidebarProfileID("work"), name: "Work", isPersistent: true, storeID: workStore)

        let profile = try engine.createProfile(record.ref)

        #expect(profile.profileID == "work")
        #expect(profile.isPersistent)
        guard case .createProfile(let got) = try #require(mock.calls.last) else {
            Issue.record("no createProfile call: \(mock.calls)")
            return
        }
        #expect(got == ProfileRef(engineID: "work", storeID: workStore, isPersistent: true))
        #expect(got.storeID == record.storeID)
    }

    @Test func restoringDefaultsToCreatingTheTabAtItsURL() async throws {
        // MockProfile and MockTab, like the CEF engine, keep no session state, so they use the contract's defaults.
        let engine = MockEngine()
        let profile: any EngineProfile = engine.defaultProfile
        let saved = Data("history".utf8)

        let restored = profile.createTab(url: docs, restoring: saved)
        let fresh = profile.createTab(url: example, restoring: nil)

        #expect(engine.openTabs.map(\.tabID) == [restored.tabID, fresh.tabID])
        #expect(engine.openTabs.map(\.initialURL) == [docs, example])
        #expect(restored.profileID == .default)
        #expect(restored.sessionState == nil)
        #expect(await restored.unload())
        #expect(restored.sessionState == nil)
    }

    @Test func assignsUniqueTabIDsAcrossProfilesAtCreation() throws {
        let engine = MockEngine()
        let work = try engine.createProfile(ref("work", true))
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

    @Test func everyProcessGoneReasonReachesTheDelegate() {
        // Chromium's termination statuses and WebKit's termination reasons (a crash, the memory or CPU limit, the
        // app's own request) each have a reason of their own.
        let reasons: [ProcessGoneReason] = [
            .crashed, .killed, .outOfMemory, .exceededCPULimit, .requestedByApp, .launchFailed, .other,
        ]
        #expect(Set(reasons) == Set(ProcessGoneReason.allCases))
        #expect(Set(reasons).count == reasons.count)
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: example)
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        for reason in reasons { engine.openTabs[0].emit(.renderProcessGone(reason)) }
        #expect(delegate.events == reasons.map { .renderProcessGone($0) })
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
        let work = try engine.createProfile(ref("work", true))
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
        _ = try engine.createProfile(ref("work-1.a_b", true))

        for id: ProfileID in ["", ".", "..", "a/b", "spaced id", "caf\u{E9}"] {
            #expect(!id.isValid)
            #expect(throws: EngineError.invalidProfileID(id)) {
                try engine.createProfile(ref(id, false))
            }
        }
        for id: ProfileID in ["default", "WORK-1.A_B"] {
            #expect(throws: EngineError.profileExists(id)) {
                try engine.createProfile(ref(id, false))
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
