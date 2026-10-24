import AppKit
import BowCore
import WebKit

/// One Bow tab on a `WKWebView`. The tab is its web view's one navigation and UI delegate, declared here once: each
/// area adds its delegate methods in its own `WebKitTab+<Area>.swift`, and the navigation callbacks go through the
/// tab's ordered `NavigationResponder` list. Whoever holds the tab keeps receiving its events; the web view holds the
/// tab weakly, as WebKit holds its delegates.
@MainActor
final class WebKitTab: SPIDelegateBase, EngineTab, WKNavigationDelegate, WKUIDelegate {
    /// The private delegate callbacks a tab answers, chosen before its web view takes it as a delegate (see
    /// `SPIDelegateBase`).
    static let privateCallbacks: Set<WebKitSPI.Callback> = [.mouseDidMoveOverElement, .processTerminated]

    /// Tab IDs are unique for the life of the process, so for the life of any engine in it.
    private static var lastTabID: UInt64 = 0

    let tabID: TabID
    let profile: WebKitProfile
    var profileID: ProfileID { profile.profileID }
    weak var delegate: (any EngineTabDelegate)?

    /// The page, nil once the tab closed. Replaced only through `install(_:)` and `releaseWebView()`.
    private(set) var webView: WebKitWebView?
    /// Set only by `refreshState()` (WebKitTab+State.swift).
    var state: EngineTabState
    private(set) var isClosed = false
    private(set) var closeReason: TabCloseReason?
    /// The page's session as the tab unloaded (WebKitTab+Unload.swift); nil otherwise.
    private(set) var sessionState: Data?

    /// The main frame navigation in progress, fed by the responders.
    var navigationEvents = NavigationEvents()
    /// Asked in order for every navigation (see `NavigationResponders`).
    let responders: [any NavigationResponder] = NavigationResponders.all()
    /// The address of the page committed last, as `EngineTabState.url` reports it (see WebKitTab+State.swift).
    var committedURL: URL?
    /// The web view's key value observations, ended when it is released.
    var observations: [NSKeyValueObservation] = []
    /// The status text sent last and where it comes from (WebKitTab+Hover.swift).
    var hover = HoverStatus()
    /// Addresses the app loaded and WebKit has not asked about yet, which make their navigation `typed`.
    private var appLoads: [URL] = []

    /// A tab on a fresh web view of `profile`, loading nothing yet.
    init(profile: WebKitProfile) {
        Self.lastTabID += 1
        tabID = TabID(rawValue: Self.lastTabID)
        self.profile = profile
        state = EngineTabState(tabID: tabID)
        super.init(privateCallbacks: Self.privateCallbacks)
        install(WebKitWebView(frame: .zero, configuration: profile.makeConfiguration()))
    }

    // MARK: The web view

    /// Makes `webView` the tab's page: the tab becomes its delegates and reads its state. The seam a tab's page
    /// is replaced through (unloading and restoring); the page before must be released first.
    func install(_ webView: WebKitWebView) {
        precondition(self.webView == nil, "release the tab's web view before installing another")
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeState(of: webView)
        observeHover(of: webView)
        observeProcessGone()
        committedURL = webView.url
        refreshState()
    }

    /// Lets the page go: stops it loading, ends the navigation in progress as aborted, drops the delegates and the
    /// observations, and takes it out of its view, so nothing in Bow keeps the web view alive.
    func releaseWebView() {
        guard let webView else { return }
        for observation in observations { observation.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        send(navigationEvents.abort())
    }

    // MARK: EngineTab

    func load(_ url: URL) {
        guard let webView else { return }
        appLoads.append(url)
        if appLoads.count > 8 { appLoads.removeFirst() }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    /// Stops the page loading. The navigation in progress fails as aborted at once, before any later start.
    func stop() {
        webView?.stopLoading()
        send(navigationEvents.abort())
        refreshState()
    }

    /// Find in page (WebKitTab+Find.swift).
    lazy var finder = TabFinder(tab: self)

    /// Releases the page; WebKit has no public way to run its beforeunload handler first, so it never keeps the
    /// tab open.
    func close() async -> Bool {
        guard !isClosed else { return true }
        releaseWebView()
        end(.closed(.app))
        return true
    }

    /// How a tab ended: closed for a reason, or unloaded with the session it saved.
    enum Ending {
        case closed(TabCloseReason)
        case unloaded(sessionState: Data?)
    }

    /// Marks the tab closed, its web view already released, and sends its last event (`closed` or `unloaded`).
    func end(_ ending: Ending) {
        precondition(!isClosed && webView == nil, "release the web view of an open tab before ending it")
        isClosed = true
        switch ending {
        case .closed(let reason):
            closeReason = reason
            send(.closed)
        case .unloaded(let sessionState):
            self.sessionState = sessionState
            send(.unloaded)
        }
    }

    // MARK: Events

    func send(_ event: TabEvent) {
        delegate?.tab(self, didReceive: event)
    }

    func send(_ events: [TabEvent]) {
        for event in events { send(event) }
    }

    /// Whether a navigation of the app's own `load(_:)` to `url` was waiting; it counts once.
    func takeAppLoad(_ url: URL) -> Bool {
        guard let index = appLoads.firstIndex(of: url) else { return false }
        appLoads.removeSubrange(...index)
        return true
    }

    /// Whether WebKit asks about `action` for a server redirect of the navigation in progress (private; without it a
    /// redirect asks as a new navigation).
    func isRedirect(_ action: WKNavigationAction) -> Bool {
        WebKitSPI.isRedirect(action) ?? false
    }

    // MARK: WKNavigationDelegate

    private func key(_ navigation: WKNavigation?) -> NavigationKey? {
        navigation.map(NavigationKey.init)
    }

    /// True when a callback comes from the tab's own web view (a released one has no delegate, but a callback may be
    /// under way).
    private func isOwn(_ webView: WKWebView) -> Bool {
        webView === self.webView
    }

    nonisolated func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            guard isOwn(webView) else { return decisionHandler(.cancel) }
            for responder in responders {
                if let policy = responder.decidePolicy(for: navigationAction, in: self) {
                    return decisionHandler(policy)
                }
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            guard isOwn(webView) else { return decisionHandler(.cancel) }
            for responder in responders {
                if let policy = responder.decidePolicy(for: navigationResponse, in: self) {
                    return decisionHandler(policy)
                }
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard isOwn(webView), let url = webView.url else { return }
            for responder in responders { responder.didStart(key(navigation), url: url, in: self) }
            refreshState()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        MainActor.assumeIsolated {
            guard isOwn(webView), let url = webView.url else { return }
            for responder in responders { responder.didRedirect(key(navigation), url: url, in: self) }
            refreshState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard isOwn(webView), let url = webView.url else { return }
            committedURL = url
            for responder in responders { responder.didCommit(key(navigation), url: url, in: self) }
            refreshState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard isOwn(webView) else { return }
            for responder in responders { responder.didFinish(key(navigation), in: self) }
            refreshState()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        MainActor.assumeIsolated {
            guard isOwn(webView) else { return }
            for responder in responders {
                responder.didFail(key(navigation), error: error, isProvisional: true, in: self)
            }
            refreshState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            guard isOwn(webView) else { return }
            for responder in responders {
                responder.didFail(key(navigation), error: error, isProvisional: false, in: self)
            }
            refreshState()
        }
    }
}
