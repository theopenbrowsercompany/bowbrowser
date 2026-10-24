import AppKit
import BowCore
import Darwin
import Testing
import WebKit

@testable import BowWebKit

/// One tab on a non persistent profile, shown in a surface view in its own off screen window, with a recording
/// delegate set before its first load is asked about. `finish()` closes the tab and checks its web view is gone.
@MainActor
final class TabRig {
    let server: FixtureServer
    let profile: WebKitProfile
    let window: TestWindow
    let surface: WebKitSurfaceView
    let delegate = RecordingTabDelegate()
    private(set) var tabs: [WebKitTab] = []

    init() throws {
        server = try FixtureServer.started()
        profile = WebKitProfile(profileID: "Test", storeID: UUID(), isPersistent: false, store: .nonPersistent())
        window = try TestHost.window()
        surface = WebKitSurfaceView(frame: window.contentView?.bounds ?? .zero)
        surface.autoresizingMask = [.width, .height]
        // Not made key (`TestHost.show`): Swift Testing runs suites side by side, and taking key from another
        // suite's window breaks its focus checks. These tests need no focus.
        window.contentView?.addSubview(surface)
    }

    /// A tab made through the profile, as the app makes one, loading `path` on the fixture server.
    func tab(_ path: String, shown: Bool = true) -> WebKitTab {
        let tab = profile.createTab(url: server.url(path)) as! WebKitTab
        tab.delegate = delegate
        // Test host only: a page in an off screen window counts as occluded, and WebKit throttles it.
        if let webView = tab.webView { WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false) }
        if shown { surface.show(tab) }
        tabs.append(tab)
        return tab
    }

    func url(_ path: String) -> URL { server.url(path) }

    /// Waits for the navigation event `name` (`finish <url>` and so on) to arrive.
    func waitFor(_ name: String, timeout: Double = 10) async throws {
        try await waitUntil("\(name); saw \(delegate.navigation)", timeout: timeout) {
            delegate.navigation.contains(name)
        }
    }

    /// Closes every tab, checks each web view is released, and stops the server and the window.
    func finish() async throws {
        var boxes: [WeakBox] = []
        for tab in tabs {
            if let webView = tab.webView { boxes.append(WeakBox(webView)) }
            _ = await tab.close()
        }
        tabs = []
        server.stop()
        TestHost.close(window)
        try await waitUntil("every web view is released", timeout: 5) { boxes.allSatisfy { $0.object == nil } }
    }
}

/// A loopback port nothing listens on: bound and closed again without listening.
func closedLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestError("no socket") }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
        }
    }
    guard bound else { throw TestError("could not bind a loopback port") }
    return UInt16(bigEndian: address.sin_port)
}

/// The navigation events of real web views keep the order `TabEvent` promises.
@Suite(.serialized) @MainActor struct NavigationOrderTests {
    init() {
        TestHost.start()
    }

    @Test func loadAndLinkSendStartCommitFinishInOrder() async throws {
        let rig = try TabRig()
        let start = rig.url("/navigation/start.html")
        let a = rig.url("/navigation/a.html")
        let tab = rig.tab("/navigation/start.html")
        try await rig.waitFor("finish \(start)")
        #expect(rig.delegate.navigation == ["start \(start)", "commit \(start)", "finish \(start)"])
        #expect(
            rig.delegate.events.contains(.didFinish(EngineNavigation(url: start, transition: .typed), httpStatus: 200)))
        #expect(rig.delegate.policyRequests == [EngineNavigation(url: start, transition: .typed)])

        rig.delegate.reset()
        try await PageDriver(tab.webView!).click("#go")
        try await rig.waitFor("finish \(a)")
        #expect(rig.delegate.navigation == ["start \(a)", "commit \(a)", "finish \(a)"])
        let link = EngineNavigation(url: a, transition: .link, isUserGesture: true)
        #expect(rig.delegate.policyRequests == [link])
        #expect(
            rig.delegate.events.first { if case .didStartNavigation = $0 { true } else { false } }
                == .didStartNavigation(link))
        try await rig.finish()
    }

    @Test func policyCancelSendsNothing() async throws {
        let rig = try TabRig()
        let start = rig.url("/navigation/start.html")
        let a = rig.url("/navigation/a.html")
        let b = rig.url("/navigation/b.html")
        let tab = rig.tab("/navigation/start.html")
        try await rig.waitFor("finish \(start)")
        rig.delegate.reset()
        rig.delegate.policy = { $0.url == b ? .cancel : .allow }
        tab.load(b)
        try await waitUntil("the policy was asked about b", timeout: 10) {
            rig.delegate.policyRequests.contains { $0.url == b }
        }
        // A navigation after the cancelled one shows the cancelled one sent nothing in between.
        tab.load(a)
        try await rig.waitFor("finish \(a)")
        #expect(rig.delegate.navigation == ["start \(a)", "commit \(a)", "finish \(a)"])
        #expect(rig.server.count(path: "/navigation/b.html") == 0)
        #expect(tab.state.url == a)
        try await rig.finish()
    }

    @Test func serverRedirectSendsStartRedirectCommitFinish() async throws {
        let rig = try TabRig()
        rig.server.route("/hop") { _ in .redirect(to: "/navigation/b.html") }
        let hop = rig.url("/hop")
        let b = rig.url("/navigation/b.html")
        _ = rig.tab("/hop")
        try await rig.waitFor("finish \(b)")
        #expect(rig.delegate.navigation == ["start \(hop)", "redirect \(b)", "commit \(b)", "finish \(b)"])
        let redirect = EngineNavigation(url: b, transition: .typed, isRedirect: true)
        #expect(rig.delegate.events.contains(.didRedirect(redirect)))
        // The redirect is asked about too, as part of the typed navigation it belongs to.
        #expect(rig.delegate.policyRequests == [EngineNavigation(url: hop, transition: .typed), redirect])
        try await rig.finish()
    }

    @Test func aRedirectThePolicyCancelsEndsItsNavigationAborted() async throws {
        let rig = try TabRig()
        rig.server.route("/hop") { _ in .redirect(to: "/navigation/b.html") }
        let hop = rig.url("/hop")
        rig.delegate.policy = { $0.isRedirect ? .cancel : .allow }
        _ = rig.tab("/hop")
        try await waitUntil("the navigation ended; saw \(rig.delegate.navigation)", timeout: 10) {
            rig.delegate.navigation.last?.hasPrefix("fail ") == true
        }
        let names = rig.delegate.navigation
        #expect(names.first == "start \(hop)")
        #expect(!names.contains { $0.hasPrefix("commit ") || $0.hasPrefix("finish ") })
        let reasons = rig.delegate.events.compactMap { if case .didFail(_, let e) = $0 { e.reason } else { nil } }
        #expect(reasons == [.aborted])
        #expect(rig.delegate.policyRequests.map(\.isRedirect) == [false, true])
        #expect(rig.server.count(path: "/navigation/b.html") == 0)
        try await rig.finish()
    }

    @Test func unreachableServerFailsWithCannotConnect() async throws {
        let rig = try TabRig()
        let dead = URL(string: "http://127.0.0.1:\(try closedLoopbackPort())/")!
        let tab = rig.tab("/navigation/start.html")
        try await rig.waitFor("finish \(rig.url("/navigation/start.html"))")
        rig.delegate.reset()
        tab.load(dead)
        try await rig.waitFor("fail \(dead)")
        #expect(rig.delegate.navigation == ["start \(dead)", "fail \(dead)"])
        let reason = rig.delegate.events.compactMap { if case .didFail(_, let e) = $0 { e.reason } else { nil } }
        #expect(reason == [.cannotConnect])
        // The tab still shows the page committed before.
        try await waitUntil("loading stopped", timeout: 5) { !tab.state.isLoading }
        #expect(tab.state.url == rig.url("/navigation/start.html"))
        try await rig.finish()
    }

    @Test func stoppedOrReplacedLoadFailsAbortedBeforeTheNextStart() async throws {
        let rig = try TabRig()
        rig.server.route("/slow") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
        let slow = rig.url("/slow")
        let a = rig.url("/navigation/a.html")
        let tab = rig.tab("/slow")
        try await rig.waitFor("start \(slow)")
        tab.stop()
        tab.load(a)
        try await rig.waitFor("finish \(a)")
        #expect(
            rig.delegate.navigation == ["start \(slow)", "fail \(slow)", "start \(a)", "commit \(a)", "finish \(a)"])
        let reasons = rig.delegate.events.compactMap { if case .didFail(_, let e) = $0 { e.reason } else { nil } }
        #expect(reasons == [.aborted])

        // A load that replaces one still under way ends it first too.
        rig.delegate.reset()
        tab.load(slow)
        try await rig.waitFor("start \(slow)")
        tab.load(a)
        try await rig.waitFor("finish \(a)")
        #expect(
            rig.delegate.navigation == ["start \(slow)", "fail \(slow)", "start \(a)", "commit \(a)", "finish \(a)"])

        // A page that committed and still loads (an image that never answers) fails aborted when stopped, before
        // the next start.
        rig.server.route("/stalled") { _ in .html("<!doctype html><title>Stalled</title><img src=\"/slow\">") }
        let stalled = rig.url("/stalled")
        rig.delegate.reset()
        tab.load(stalled)
        try await rig.waitFor("commit \(stalled)")
        tab.stop()
        tab.load(a)
        try await rig.waitFor("finish \(a)")
        #expect(
            rig.delegate.navigation == [
                "start \(stalled)", "commit \(stalled)", "fail \(stalled)", "start \(a)", "commit \(a)", "finish \(a)",
            ])
        try await rig.finish()
    }
}

/// The rules of `NavigationEvents` on their own, with WebKit's callbacks in the orders WebKit can make them.
@Suite struct NavigationEventsTests {
    // Kept alive, so their identities stay distinct.
    private let objects = [NSObject(), NSObject()]
    private var one: NavigationKey { ObjectIdentifier(objects[0]) }
    private var two: NavigationKey { ObjectIdentifier(objects[1]) }
    private let a = URL(string: "http://h/a")!
    private let b = URL(string: "http://h/b")!

    private func names(_ events: [TabEvent]) -> [String] {
        events.compactMap { event in
            switch event {
            case .didStartNavigation(let n): "start \(n.url.path)"
            case .didRedirect(let n): "redirect \(n.url.path)"
            case .didCommit(let n): "commit \(n.url.path)"
            case .didFinish(let n, let status): "finish \(n.url.path) \(status)"
            case .didFail(let n, let e): "fail \(n.url.path) \(e.isAborted ? "aborted" : "error")"
            default: nil
            }
        }
    }

    @Test func aStartEndsTheNavigationInProgressAndItsLateFailureIsDropped() {
        var events = NavigationEvents()
        var all = events.started(one, url: a)
        all += events.started(two, url: b)
        all += events.failed(one, error: NavigationError(reason: .aborted, description: ""))
        all += events.committed(two, url: b)
        all += events.finished(two)
        #expect(names(all) == ["start /a", "fail /a aborted", "start /b", "commit /b", "finish /b 0"])
    }

    @Test func aCommitWithNoStartStartsItsOwnNavigation() {
        var events = NavigationEvents()
        var all = events.committed(nil, url: a)
        all += events.finished(nil)
        all += events.started(one, url: b)
        all += events.committed(one, url: b)
        all += events.committed(two, url: a)
        #expect(
            names(all) == [
                "start /a", "commit /a", "finish /a 0", "start /b", "commit /b", "fail /b aborted", "start /a",
                "commit /a",
            ])
    }

    @Test func callbacksOutOfPlaceAreDropped() {
        var events = NavigationEvents()
        var all = events.finished(one)
        all += events.failed(one, error: NavigationError(reason: .other, description: ""))
        all += events.started(one, url: a)
        // A finish before the commit, and a redirect after it, are not WebKit's order and send nothing.
        all += events.finished(one)
        events.responded(one, httpStatus: 404)
        all += events.committed(one, url: a)
        all += events.redirected(one, url: b)
        all += events.finished(two)
        all += events.finished(one)
        #expect(names(all) == ["start /a", "commit /a", "finish /a 404"])
        #expect(!events.isActive)
        #expect(events.abort().isEmpty)
    }

    @Test func theAllowedNavigationGivesItsStartTransitionOnlyForItsAddress() {
        var events = NavigationEvents()
        events.allow(EngineNavigation(url: a, transition: .link, isUserGesture: true))
        let first = events.started(one, url: b)
        #expect(first == [.didStartNavigation(EngineNavigation(url: b, transition: .other))])
        _ = events.abort()
        events.allow(EngineNavigation(url: a, transition: .link, isUserGesture: true))
        let second = events.started(two, url: a)
        #expect(second == [.didStartNavigation(EngineNavigation(url: a, transition: .link, isUserGesture: true))])
        #expect(events.isProvisional)
        let redirect = events.redirected(two, url: b)
        #expect(
            redirect == [
                .didRedirect(EngineNavigation(url: b, transition: .link, isUserGesture: true, isRedirect: true))
            ])
        let commit = events.committed(two, url: b)
        #expect(commit == [.didCommit(EngineNavigation(url: b, transition: .link, isUserGesture: true))])
        #expect(!events.isProvisional && events.isActive)
    }

    @Test func webKitErrorsMapToBowReasons() {
        #expect(NavigationError.reason(domain: NSURLErrorDomain, code: NSURLErrorCancelled) == .aborted)
        #expect(NavigationError.reason(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost) == .cannotConnect)
        #expect(NavigationError.reason(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost) == .nameNotResolved)
        #expect(NavigationError.reason(domain: NSURLErrorDomain, code: NSURLErrorTimedOut) == .timedOut)
        #expect(NavigationError.reason(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet) == .offline)
        #expect(
            NavigationError.reason(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted) == .certificate
        )
        #expect(NavigationError.reason(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL) == .badAddress)
        #expect(NavigationError.reason(domain: "WebKitErrorDomain", code: 102) == .aborted)
        #expect(NavigationError.reason(domain: "WebKitErrorDomain", code: 103) == .blocked)
        #expect(NavigationError.reason(domain: "SomethingElse", code: 1) == .other)
        #expect(NavigationTransition(.other, isAppLoad: true) == .typed)
        #expect(NavigationTransition(.other, isAppLoad: false) == .other)
        #expect(NavigationTransition(.linkActivated, isAppLoad: false) == .link)
        #expect(NavigationTransition(.backForward, isAppLoad: false) == .backForward)
    }
}
