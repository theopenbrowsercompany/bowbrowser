import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab's state follows its web view, the surface view shows one tab at a time, and closing a tab lets its page
/// go.
@Suite(.serialized) @MainActor struct TabStateTests {
    init() {
        TestHost.start()
    }

    private func lastState(_ delegate: RecordingTabDelegate) -> EngineTabState? {
        delegate.events.reversed().lazy.compactMap { if case .stateChanged(let s) = $0 { s } else { nil } }.first
    }

    @Test func stateFollowsLoadsAndHistory() async throws {
        let rig = try TabRig()
        let start = rig.url("/navigation/start.html")
        let a = rig.url("/navigation/a.html")
        let tab = rig.tab("/navigation/start.html")
        try await waitUntil("start loaded", timeout: 10) {
            tab.state.url == start && !tab.state.isLoading && tab.state.title == "Navigation start"
        }
        #expect(tab.state.title == "Navigation start")
        #expect(!tab.state.canGoBack && !tab.state.canGoForward)
        #expect(tab.state.tabID == tab.tabID)

        tab.load(a)
        try await waitUntil("a loaded", timeout: 10) {
            tab.state.url == a && !tab.state.isLoading && tab.state.title == "A" && tab.state.canGoBack
                && !tab.state.canGoForward
        }
        #expect(tab.state.canGoBack && !tab.state.canGoForward)

        tab.goBack()
        try await waitUntil("back at start", timeout: 10) {
            tab.state.url == start && !tab.state.isLoading && tab.state.title == "Navigation start"
                && tab.state.canGoForward && !tab.state.canGoBack
        }
        #expect(tab.state.title == "Navigation start" && !tab.state.canGoBack)

        tab.goForward()
        try await waitUntil("forward at a", timeout: 10) {
            tab.state.url == a && !tab.state.isLoading && tab.state.canGoBack && !tab.state.canGoForward
        }
        #expect(tab.state.canGoBack && !tab.state.canGoForward)
        // Every change was pushed: the last stateChanged is the state.
        #expect(lastState(rig.delegate) == tab.state)

        // A same document change (history.pushState) moves the address with no navigation.
        rig.delegate.reset()
        _ = try await PageDriver(tab.webView!).eval("history.pushState({}, '', 'a.html#moved'); return true")
        let moved = rig.url("/navigation/a.html#moved")
        try await waitUntil("the pushed address", timeout: 5) { tab.state.url == moved }
        #expect(rig.delegate.navigation.isEmpty)
        try await rig.finish()
    }

    @Test func addressStaysCommittedWhileANavigationIsProvisional() async throws {
        let rig = try TabRig()
        rig.server.route("/slow") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
        let start = rig.url("/navigation/start.html")
        let slow = rig.url("/slow")
        let tab = rig.tab("/navigation/start.html")
        try await rig.waitFor("finish \(start)")
        tab.load(slow)
        try await rig.waitFor("start \(slow)")
        try await waitUntil("loading", timeout: 5) { tab.state.isLoading }
        #expect(tab.state.url == start, "the address moved before the slow page committed")
        tab.stop()
        try await waitUntil("loading stopped", timeout: 5) { !tab.state.isLoading }
        #expect(tab.state.url == start)
        #expect(lastState(rig.delegate)?.url == start)
        try await rig.finish()
    }

    @Test func surfaceViewShowsOneTabAndKeepsTheOthersAlive() async throws {
        let rig = try TabRig()
        let start = rig.url("/navigation/start.html")
        let a = rig.url("/navigation/a.html")
        let first = rig.tab("/navigation/start.html")
        let second = rig.tab("/navigation/a.html", shown: false)
        try await waitUntil("both loaded", timeout: 10) {
            first.state.url == start && second.state.url == a && !first.state.isLoading && !second.state.isLoading
        }
        #expect(rig.surface.isShowing(first) && !rig.surface.isShowing(second))
        #expect(first.webView?.superview === rig.surface)

        rig.surface.show(second)
        #expect(rig.surface.isShowing(second) && !rig.surface.isShowing(first))
        #expect(first.webView?.superview == nil && rig.surface.subviews.count == 1)
        // The detached page is alive: it still answers.
        #expect(try await PageDriver(first.webView!).string("return document.title") == "Navigation start")
        #expect(!first.isClosed)

        // Moving a page to another surface view takes it out of this one.
        let other = WebKitSurfaceView(frame: rig.surface.frame)
        rig.window.contentView?.addSubview(other)
        #expect(!other.showsTab)
        other.show(second)
        #expect(other.showsTab && !rig.surface.showsTab)
        #expect(other.isShowing(second) && !rig.surface.isShowing(second) && rig.surface.subviews.isEmpty)
        other.detach()
        #expect(!other.showsTab)
        #expect(!other.isShowing(second) && second.webView?.superview == nil)
        try await rig.finish()
    }

    @Test func closeEndsTheNavigationAndReleasesTheWebView() async throws {
        let rig = try TabRig()
        rig.server.route("/slow") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
        let slow = rig.url("/slow")
        let tab = rig.tab("/slow")
        try await rig.waitFor("start \(slow)")
        weak let webView = tab.webView
        #expect(await tab.close())
        #expect(tab.isClosed && tab.closeReason == .app && tab.webView == nil)
        #expect(rig.delegate.navigation == ["start \(slow)", "fail \(slow)"])
        #expect(rig.delegate.events.last == .closed)
        #expect(!rig.surface.isShowing(tab) && rig.surface.subviews.isEmpty)
        // Commands on a closed tab do nothing, and closing again is a no-op.
        tab.load(rig.url("/navigation/a.html"))
        tab.reload()
        #expect(await tab.close())
        #expect(rig.delegate.events.filter { $0 == .closed }.count == 1)
        try await waitUntil("the web view is released", timeout: 5) { webView == nil }
        try await rig.finish()
    }
}
