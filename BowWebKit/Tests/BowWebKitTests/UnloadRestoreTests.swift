import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// Unloading a tab and making a new one from the session it kept (W1 criterion 1), and the navigation events of the
/// WebKit flows the restore leans on: going back to a cached page, a 204 answer, and WebKit callbacks without a
/// `WKNavigation`.
@Suite(.serialized) @MainActor struct UnloadRestoreTests {
    init() {
        TestHost.start()
    }

    /// What a restored tab must show again.
    struct Saved {
        var n: Int
        var url: URL
        var back: [URL]
        var forward: [URL]
        var scrollY: Double
        var sessionState: Data?
    }

    private func page(_ rig: TabRig, _ n: Int, _ step: String) -> URL {
        rig.url("/restore/page.html?tab=\(n)&step=\(step)")
    }

    /// Loads steps a, b and c in `tab`, goes back once to b and scrolls to 500 + 97n px, then waits until WebKit has
    /// written the scroll position into the session (it does so a moment after the scroll).
    private func prepare(_ rig: TabRig, _ tab: WebKitTab, n: Int) async throws -> Saved {
        rig.surface.show(tab)
        let webView = try #require(tab.webView)
        let driver = PageDriver(webView)
        try await driver.waitForLoad(of: page(rig, n, "a"))
        for step in ["b", "c"] {
            tab.load(page(rig, n, step))
            try await driver.waitForLoad(of: page(rig, n, step))
        }
        tab.goBack()
        try await driver.waitForLoad(of: page(rig, n, "b"))
        let unscrolled = webView.interactionState as? Data
        let y = Double(500 + 97 * n)
        _ = try await driver.eval("window.scrollTo(0, y); return window.scrollY", ["y": y])
        try await waitUntil("tab \(n) scrolled") { try await driver.number("return window.scrollY") == y }
        try await waitUntil("tab \(n) scroll saved in the session") {
            (webView.interactionState as? Data) != unscrolled
        }
        let list = webView.backForwardList
        return Saved(
            n: n, url: try #require(webView.url), back: list.backList.map(\.url), forward: list.forwardList.map(\.url),
            scrollY: y)
    }

    /// Shows the restored `tab` and checks it is back on the saved entry with the saved back and forward lists and
    /// scroll position, then that back lands on a and forward twice on c. Returns a weak reference to its web view,
    /// held by nothing here once this returns.
    private func checkRestore(_ rig: TabRig, _ tab: WebKitTab, _ saved: Saved) async throws -> WeakBox {
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        let webView = try #require(tab.webView)
        WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false)
        rig.surface.show(tab)
        let driver = PageDriver(webView)
        let finish = "finish \(saved.url.absoluteString)"
        try await waitUntil("tab \(saved.n) restored", timeout: 10) {
            let list = webView.backForwardList
            let scrollY = try await driver.number("return document.readyState === 'complete' ? window.scrollY : -1")
            return webView.url == saved.url && list.backList.map(\.url) == saved.back
                && list.forwardList.map(\.url) == saved.forward && abs(scrollY - saved.scrollY) <= 2
                && tab.state.url == saved.url && tab.state.canGoBack && tab.state.canGoForward
                && delegate.navigation.last == finish
        }
        #expect(abs(try await driver.number("return window.scrollY") - saved.scrollY) <= 2)

        tab.goBack()
        try await driver.waitForLoad(of: page(rig, saved.n, "a"))
        tab.goForward()
        try await driver.waitForLoad(of: saved.url)
        tab.goForward()
        try await driver.waitForLoad(of: page(rig, saved.n, "c"))
        return WeakBox(webView)
    }

    @Test func twentyUnloadedTabsComeBackWithAddressHistoryAndScroll() async throws {
        let rig = try TabRig()
        let count = 20
        var live: [(tab: WebKitTab, saved: Saved, delegate: RecordingTabDelegate)] = []
        for n in 1...count {
            let tab = rig.tab("/restore/page.html?tab=\(n)&step=a")
            let delegate = RecordingTabDelegate()
            tab.delegate = delegate
            live.append((tab, try await prepare(rig, tab, n: n), delegate))
        }
        rig.surface.detach()

        // All twenty unloaded together: each ends with `unloaded`, keeps its session and lets its web view go.
        var boxes: [WeakBox] = []
        for index in live.indices {
            let tab = live[index].tab
            if let webView = tab.webView { boxes.append(WeakBox(webView)) }
            #expect(await tab.unload())
            #expect(tab.isClosed && tab.closeReason == nil && tab.webView == nil)
            #expect(live[index].delegate.events.last == .unloaded)
            live[index].saved.sessionState = tab.sessionState
            #expect(tab.sessionState != nil)
        }
        try await waitUntil("twenty unloaded web views released", timeout: 10) {
            boxes.allSatisfy { $0.object == nil }
        }

        // Each made again from its session, one at a time as a window would show them.
        for (_, saved, _) in live {
            let tab = try #require(
                rig.profile.createTab(url: saved.url, restoring: saved.sessionState) as? WebKitTab)
            let box = try await checkRestore(rig, tab, saved)
            #expect(await tab.close())
            try await waitUntil("restored web view \(saved.n) released") { box.object == nil }
        }
        try await rig.finish()
    }

    @Test func unloadEndsTheTabOnceAndARestoreWithoutUsableStateLoadsTheAddress() async throws {
        let rig = try TabRig()
        rig.server.route("/slow") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
        let a = rig.url("/navigation/a.html")
        let slow = rig.url("/slow")
        let tab = rig.tab("/navigation/a.html")
        try await rig.waitFor("finish \(a)")

        // A navigation in progress fails as aborted before `unloaded`, which is the last event.
        rig.delegate.reset()
        tab.load(slow)
        try await rig.waitFor("start \(slow)")
        #expect(await tab.unload())
        #expect(rig.delegate.navigation == ["start \(slow)", "fail \(slow)"])
        let reasons = rig.delegate.events.compactMap { if case .didFail(_, let e) = $0 { e.reason } else { nil } }
        #expect(reasons == [.aborted])
        #expect(rig.delegate.events.last == .unloaded)
        #expect(tab.closeReason == nil)
        let state = try #require(tab.sessionState)

        // Unloading or closing again changes nothing and sends nothing.
        let sent = rig.delegate.events.count
        #expect(await tab.unload() == false)
        #expect(await tab.close())
        #expect(rig.delegate.events.count == sent)
        #expect(tab.sessionState == state && tab.closeReason == nil)

        // A tab closed rather than unloaded keeps no session.
        let closed = rig.tab("/navigation/a.html", shown: false)
        try await waitUntil("the second tab loaded") { closed.state.url == a && !closed.state.isLoading }
        #expect(await closed.close())
        #expect(closed.sessionState == nil && closed.closeReason == .app)

        // No state, or state WebKit cannot read, loads the address given.
        for restoring in [nil, Data("not a session".utf8)] {
            let delegate = RecordingTabDelegate()
            let fresh = try #require(rig.profile.createTab(url: a, restoring: restoring) as? WebKitTab)
            fresh.delegate = delegate
            try await waitUntil("a tab restoring \(String(describing: restoring)) loaded a; saw \(delegate.navigation)")
            {
                delegate.navigation.contains("finish \(a)") && fresh.state.url == a && !fresh.state.isLoading
            }
            #expect(delegate.navigation == ["start \(a)", "commit \(a)", "finish \(a)"])
            #expect(fresh.state.canGoBack == false && fresh.state.canGoForward == false)
            #expect(await fresh.close())
        }

        // The session restores the page the tab was on with no request needed for its address.
        let restored = try #require(rig.profile.createTab(url: slow, restoring: state) as? WebKitTab)
        let delegate = RecordingTabDelegate()
        restored.delegate = delegate
        // A session saved during a load comes back on the entry the tab was on, not the address it was loading.
        try await waitUntil("the restored tab is back on a; saw \(delegate.navigation)") {
            delegate.navigation.contains("finish \(a)") && restored.state.url == a
        }
        #expect(delegate.navigation == ["start \(a)", "commit \(a)", "finish \(a)"])
        #expect(await restored.close())

        // Closing while an unload waits for a load to stop wins: the unload returns false and saves nothing.
        let racing = rig.tab("/navigation/a.html", shown: false)
        try await waitUntil("the racing tab loaded") { racing.state.url == a && !racing.state.isLoading }
        let racingEvents = RecordingTabDelegate()
        racing.delegate = racingEvents
        racing.load(slow)
        try await waitUntil("the racing tab is loading") { racingEvents.navigation.contains("start \(slow)") }
        async let unloaded = racing.unload()
        #expect(await racing.close())
        #expect(await unloaded == false)
        #expect(racing.sessionState == nil && racing.closeReason == .app)
        #expect(racingEvents.events.last == .closed && !racingEvents.events.contains(.unloaded))
        try await rig.finish()
    }

    @Test func goingBackToACachedPageStartsCommitsAndFinishesWithStatusZero() async throws {
        let rig = try TabRig()
        let one = page(rig, 1, "a")
        let two = page(rig, 1, "b")
        let tab = rig.tab("/restore/page.html?tab=1&step=a")
        try await rig.waitFor("finish \(one)")
        let loadID = "return document.documentElement.dataset.loadId ?? ''"
        let firstLoad = try await PageDriver(try #require(tab.webView)).string(loadID)
        #expect(!firstLoad.isEmpty)
        tab.load(two)
        try await rig.waitFor("finish \(two)")
        rig.delegate.reset()
        tab.goBack()
        try await rig.waitFor("finish \(one)")
        // The page came from the back/forward cache: the same document, shown again.
        try await waitUntil("the cached page is shown again") {
            try await PageDriver(try #require(tab.webView)).string(
                "return document.documentElement.dataset.persisted ?? ''") == "true"
        }
        #expect(try await PageDriver(try #require(tab.webView)).string(loadID) == firstLoad)
        #expect(rig.delegate.navigation == ["start \(one)", "commit \(one)", "finish \(one)"])
        let back = EngineNavigation(url: one, transition: .backForward)
        #expect(rig.delegate.events.contains(.didFinish(back, httpStatus: 0)))
        try await waitUntil("loading stopped") { !tab.state.isLoading }
        #expect(rig.delegate.navigation == ["start \(one)", "commit \(one)", "finish \(one)"])
        try await rig.finish()
    }

    @Test func aNoContentAnswerFailsAbortedWithNoCommit() async throws {
        let rig = try TabRig()
        rig.server.route("/empty") { _ in FixtureServer.Response(status: 204) }
        let a = rig.url("/navigation/a.html")
        let empty = rig.url("/empty")
        let tab = rig.tab("/navigation/a.html")
        try await rig.waitFor("finish \(a)")
        rig.delegate.reset()
        tab.load(empty)
        try await rig.waitFor("fail \(empty)")
        #expect(rig.delegate.navigation == ["start \(empty)", "fail \(empty)"])
        let reasons = rig.delegate.events.compactMap { if case .didFail(_, let e) = $0 { e.reason } else { nil } }
        #expect(reasons == [.aborted])
        try await waitUntil("loading stopped on a") { !tab.state.isLoading && tab.state.url == a }
        // The next navigation is whole: nothing late from the 204 ends it.
        rig.delegate.reset()
        tab.load(rig.url("/navigation/b.html"))
        try await rig.waitFor("finish \(rig.url("/navigation/b.html"))")
        #expect(rig.delegate.navigation.count == 3)
        try await rig.finish()
    }

    /// Which WebKit callbacks come without a `WKNavigation` in the flows above, read from a bare web view: a nil
    /// failure must never end a navigation it does not belong to.
    @Test func webKitCallbacksWithoutANavigation() async throws {
        let server = try FixtureServer.started()
        server.route("/empty") { _ in FixtureServer.Response(status: 204) }
        server.route("/slow") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
        let (window, webView) = try TestHost.webView()
        let log = BareNavigationLog()
        webView.navigationDelegate = log
        let a = server.url("/restore/page.html?tab=1&step=a")
        let b = server.url("/restore/page.html?tab=1&step=b")
        let driver = PageDriver(webView)
        try await driver.load(a)
        try await driver.load(b)
        webView.goBack()
        try await driver.waitForLoad(of: a)
        webView.load(URLRequest(url: server.url("/empty")))
        try await waitUntil("the 204 ended; saw \(log.calls)") { log.calls.last?.hasPrefix("failProvisional") == true }
        webView.load(URLRequest(url: server.url("/slow")))
        try await waitUntil("the slow load started") { log.calls.last?.hasPrefix("start") == true }
        webView.load(URLRequest(url: b))
        try await driver.waitForLoad(of: b)
        try await waitUntil("loading stopped") { !webView.isLoading }
        print("bare navigation callbacks: \(log.calls)")
        #expect(!log.calls.contains { $0.hasSuffix(" nil") })
        #expect(log.calls.filter { $0.hasPrefix("failProvisional") }.count == 2)
        _ = webView.dispose()
        server.stop()
        TestHost.close(window)

        // Should one come anyway, a failure without a navigation cannot end the next one, which has its own.
        let one = NavigationKey(NSObject())
        let two = NavigationKey(NSObject())
        let x = URL(string: "http://h/x")!
        let y = URL(string: "http://h/y")!
        var events = NavigationEvents()
        var all = events.started(one, url: x)
        all += events.started(two, url: y)
        all += events.failed(nil, error: NavigationError(reason: .other, description: ""))
        all += events.committed(two, url: y)
        all += events.finished(two)
        #expect(
            all.map(\.shortName) == ["start /x", "fail /x", "start /y", "commit /y", "finish /y"])
        // A navigation WebKit started without one (nil key) still ends on a failure without one.
        all = events.committed(nil, url: x)
        all += events.failed(nil, error: NavigationError(reason: .other, description: ""))
        #expect(all.map(\.shortName) == ["start /x", "commit /x", "fail /x"])
    }
}

extension TabEvent {
    /// `start /path` and so on for the navigation events, `other` for the rest.
    fileprivate var shortName: String {
        switch self {
        case .didStartNavigation(let n): "start \(n.url.path)"
        case .didRedirect(let n): "redirect \(n.url.path)"
        case .didCommit(let n): "commit \(n.url.path)"
        case .didFinish(let n, _): "finish \(n.url.path)"
        case .didFail(let n, _): "fail \(n.url.path)"
        default: "other"
        }
    }
}

/// Records a bare web view's main frame navigation callbacks as `<callback> <navigation or nil>`, the navigation
/// named by its order of first appearance.
@MainActor
final class BareNavigationLog: NSObject, WKNavigationDelegate {
    private(set) var calls: [String] = []
    private var seen: [ObjectIdentifier] = []
    /// Held so a navigation's address is not reused by a later one while the test runs.
    private var held: [WKNavigation] = []

    private func record(_ name: String, _ navigation: WKNavigation?) {
        guard let navigation else { return calls.append("\(name) nil") }
        let id = ObjectIdentifier(navigation)
        if !seen.contains(id) {
            seen.append(id)
            held.append(navigation)
        }
        calls.append("\(name) #\(seen.firstIndex(of: id)! + 1)")
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { record("start", navigation) }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated { record("commit", navigation) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { record("finish", navigation) }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        MainActor.assumeIsolated { record("failProvisional", navigation) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { record("fail", navigation) }
    }
}
