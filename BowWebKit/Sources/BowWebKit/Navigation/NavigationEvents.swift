import BowCore
import Foundation
import WebKit

/// Which WebKit navigation a callback belongs to: the `WKNavigation` object, compared by identity (nil where WebKit
/// passed none, as it may for a page restored from the back/forward cache). Held strongly while it is in progress
/// or recently ended, so a new navigation cannot reuse its address and be taken for it.
struct NavigationKey: Equatable {
    let object: AnyObject

    init(_ object: AnyObject) { self.object = object }

    static func == (a: NavigationKey, b: NavigationKey) -> Bool { a.object === b.object }
}

/// Turns WebKit's main frame navigation callbacks into Bow's navigation events, in the order `TabEvent` promises:
/// start, then any redirects, then commit, then finish or fail, and every started navigation ends before the next
/// one starts. Plain values only, so its rules are tested without a web view.
///
/// WebKit does not keep that order by itself: a navigation that replaces one still loading can start before the old
/// one's failure arrives, and a stopped committed page may never hear again. So a start, a stop or a close ends the
/// navigation in progress at once as aborted, and a later WebKit callback for a navigation already ended is dropped.
/// A navigation the policy cancels never starts in WebKit, so it sends nothing.
struct NavigationEvents {
    private struct Active {
        var key: NavigationKey?
        var navigation: EngineNavigation
        var isCommitted = false
        /// The main frame response's HTTP status, 0 until one arrives (and for schemes without one).
        var httpStatus = 0
    }

    private var active: Active? {
        didSet {
            // Remember the navigation that just ended, so WebKit's late callbacks for it (a commit or failure
            // already under way when Bow stopped or replaced it) are dropped rather than taken for a new one.
            guard let key = oldValue?.key, active?.key != key, !ended.contains(key) else { return }
            ended.append(key)
            if ended.count > 16 { ended.removeFirst() }
        }
    }
    /// Navigations ended lately, newest last.
    private var ended: [NavigationKey] = []
    /// The last main frame navigation the policy allowed, waiting for WebKit to start it; it gives the start its
    /// transition and gesture.
    private var allowed: EngineNavigation?

    /// True while a navigation has started and not yet committed: the tab keeps showing the committed address.
    var isProvisional: Bool { active.map { !$0.isCommitted } ?? false }

    /// True while a navigation has started and not yet ended.
    var isActive: Bool { active != nil }

    /// The navigation in progress, as last reported.
    var current: EngineNavigation? { active?.navigation }

    /// The policy allowed `navigation`, a new main frame navigation (not a redirect).
    mutating func allow(_ navigation: EngineNavigation) {
        allowed = navigation
    }

    /// WebKit started a provisional navigation to `url`. Ends the navigation in progress first.
    mutating func started(_ key: NavigationKey?, url: URL) -> [TabEvent] {
        var events = abort()
        var navigation = EngineNavigation(url: url, transition: .other)
        if let allowed, allowed.url == url { navigation = allowed }
        navigation.url = url
        navigation.isRedirect = false
        allowed = nil
        active = Active(key: key, navigation: navigation)
        events.append(.didStartNavigation(navigation))
        return events
    }

    /// The server redirected the navigation in progress to `url`.
    mutating func redirected(_ key: NavigationKey?, url: URL) -> [TabEvent] {
        guard var current = active, belongs(key), !current.isCommitted else { return [] }
        current.navigation.url = url
        current.navigation.isRedirect = true
        active = current
        return [.didRedirect(current.navigation)]
    }

    /// The main frame's response arrived with `httpStatus`.
    mutating func responded(_ key: NavigationKey?, httpStatus: Int) {
        guard belongs(key), active?.isCommitted == false else { return }
        active?.httpStatus = httpStatus
    }

    /// The navigation committed at `url`. A commit of no navigation in progress (one WebKit did not start, or one
    /// after the navigation in progress committed already) is a navigation of its own: its start comes first.
    mutating func committed(_ key: NavigationKey?, url: URL) -> [TabEvent] {
        if isEnded(key) { return [] }
        var events: [TabEvent] = []
        if active == nil || !belongs(key) || active?.isCommitted == true {
            events += started(key, url: url)
        }
        guard var current = active else { return events }
        current.isCommitted = true
        current.navigation.url = url
        current.navigation.isRedirect = false
        active = current
        events.append(.didCommit(current.navigation))
        return events
    }

    /// The committed navigation finished loading.
    mutating func finished(_ key: NavigationKey?) -> [TabEvent] {
        guard let current = active, belongs(key), current.isCommitted else { return [] }
        active = nil
        return [.didFinish(current.navigation, httpStatus: current.httpStatus)]
    }

    /// The navigation failed, before or after committing. A failure of a navigation already ended is dropped.
    mutating func failed(_ key: NavigationKey?, error: NavigationError) -> [TabEvent] {
        guard let current = active, belongs(key) else { return [] }
        active = nil
        return [.didFail(current.navigation, error)]
    }

    /// Ends the navigation in progress, if any, as aborted: the app stopped it, a newer one replaced it, or the
    /// tab closed.
    mutating func abort() -> [TabEvent] {
        guard let current = active else { return [] }
        active = nil
        return [.didFail(current.navigation, .abortedByBow)]
    }

    private func isEnded(_ key: NavigationKey?) -> Bool {
        key.map { ended.contains($0) } ?? false
    }

    private func belongs(_ key: NavigationKey?) -> Bool {
        guard let active, !isEnded(key) else { return false }
        guard let key, let own = active.key else { return true }
        return key == own
    }
}

/// Feeds the tab's `NavigationEvents` with WebKit's main frame callbacks and sends what it returns to the app. It
/// reads the main frame response's status and answers no policy.
@MainActor
final class NavigationEventResponder: NavigationResponder {
    func decidePolicy(for response: WKNavigationResponse, in tab: WebKitTab) -> WKNavigationResponsePolicy? {
        if response.isForMainFrame {
            tab.navigationEvents.responded(nil, httpStatus: (response.response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return nil
    }

    func didStart(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {
        tab.send(tab.navigationEvents.started(key, url: url))
    }

    func didRedirect(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {
        tab.send(tab.navigationEvents.redirected(key, url: url))
    }

    func didCommit(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {
        tab.send(tab.navigationEvents.committed(key, url: url))
    }

    func didFinish(_ key: NavigationKey?, in tab: WebKitTab) {
        tab.send(tab.navigationEvents.finished(key))
    }

    func didFail(_ key: NavigationKey?, error: any Error, isProvisional: Bool, in tab: WebKitTab) {
        tab.send(tab.navigationEvents.failed(key, error: NavigationError(error)))
    }
}
