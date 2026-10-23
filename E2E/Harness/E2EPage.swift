import AppKit

// The small protocol e2e tests use to drive the app. Tests never touch engine or window types directly:
// E2EAppAdapter.swift implements these on today's bridge, so reshaping the bridge swaps that one file.

/// The app as a test sees it.
@MainActor
protocol E2EApp: AnyObject {
    /// Opens a browser window on `url`, off screen and never key, and returns its page (the window's first tab).
    /// `profile` names a profile to create for the window; nil uses the default profile.
    /// Throws when the window would be visible on a screen or the app could take focus.
    func openWindow(at url: URL, newProfile profile: E2EProfile?) async throws -> any E2EPage
    /// Opens `url` in a new tab of the window `page` is in, selected unless `select` is false.
    func openTab(at url: URL, besides page: any E2EPage, select: Bool) throws -> any E2EPage
    /// Selects the tab `page` is in, showing it in its window.
    func select(_ page: any E2EPage) throws
    /// Closes the tab `page` is in, running its page's beforeunload handler. Returns true once the tab has closed,
    /// and false when the page's leave prompt was answered with stay (see `E2EPage.leavePromptAnswer`).
    func closeTab(_ page: any E2EPage) async throws -> Bool
    /// Closes the window `page` is in the way its close button does, and returns once the window has closed.
    func closeWindow(of page: any E2EPage) async throws
    /// The first page of the window opened last, which the run's final.png shows when that page is still the one
    /// its window shows; nil before any window opened and after quit().
    var lastOpenedPage: (any E2EPage)? { get }
    /// Quits the way the app's Quit menu item does.
    func quit()
}

extension E2EApp {
    func openWindow(at url: URL) async throws -> any E2EPage {
        try await openWindow(at: url, newProfile: nil)
    }
}

/// A profile for `E2EApp.openWindow` to create: on disk when persistent, in memory otherwise.
struct E2EProfile {
    var id: String
    var isPersistent: Bool
}

/// One web page: a tab in a browser window.
@MainActor
protocol E2EPage: AnyObject {
    /// True while the page's tab is the one its window shows.
    var isShown: Bool { get }
    /// True once the page's tab has closed.
    var isClosed: Bool { get }
    /// How many main frame loads have finished (or failed) in this page so far, starting at 0 when the window
    /// opens. Read it before starting a navigation and pass it to `waitForLoad(after:)`.
    var finishedLoads: Int { get }
    /// Waits for load number `finishedLoads + 1` to finish and returns its HTTP status, or throws if it failed.
    /// Returns at once when that load already finished; loads that finished before it never count.
    /// The window's first page is `waitForLoad(after: 0)`.
    func waitForLoad(after finishedLoads: Int) async throws -> Int
    /// Starts loading `url` in the page's tab, the way the address bar does.
    func load(_ url: URL)
    /// Every main frame navigation event the page's tab reported, in order, starting when the window opens.
    var navigationEvents: [E2ENavigationEvent] { get }
    /// Asked before every main frame navigation and redirect, with its URL: false cancels it, and the canceled
    /// navigation reports no events. Nil allows every navigation.
    var navigationPolicy: ((URL) -> Bool)? { get set }
    /// How the page's "leave this site?" prompt is answered when its beforeunload handler asks: true leaves (the
    /// default, so quitting never waits on a prompt), false stays. The prompt never shows on screen.
    var leavePromptAnswer: Bool { get set }
    /// How many leave prompts the page's tab has asked so far.
    var leavePrompts: Int { get }
    /// Calls a Chrome DevTools protocol method and returns its result object.
    func devTools(_ method: String, _ params: [String: Any]) async throws -> [String: Any]
    /// The view that shows the page's web content, for screenshots; nil while another tab of its window is shown
    /// and once it is gone.
    var contentView: NSView? { get }
}

extension E2EPage {
    /// Evaluates `expression` in the page and returns its value as JSON types (nil for undefined or null).
    /// A promise is awaited, so an expression can wait on a page state change without fixed sleeps.
    func evaluate(_ expression: String) async throws -> Any? {
        let response = try await devTools(
            "Runtime.evaluate",
            ["expression": expression, "returnByValue": true, "awaitPromise": true]
        )
        if let details = response["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = exception?["description"] as? String ?? details["text"] as? String ?? "exception"
            throw E2EError("\(expression) threw: \(text)")
        }
        return (response["result"] as? [String: Any])?["value"]
    }

    /// Evaluates `expression` and returns it as a string, throwing when it is something else.
    func string(_ expression: String) async throws -> String {
        let value = try await evaluate(expression)
        guard let string = value as? String else {
            throw E2EError("\(expression) is \(value.map { "\($0)" } ?? "null"), not a string")
        }
        return string
    }
}

/// One main frame navigation event: a navigation started, was redirected, committed, finished or failed.
struct E2ENavigationEvent: Equatable, CustomStringConvertible {
    enum Kind: String {
        case start, redirect, commit, finish, fail
    }

    var kind: Kind
    /// The navigation's URL: for a redirect the URL redirected to, for a commit the URL committed.
    var url: URL
    /// The HTTP status for finish, the network error code for fail (negative), 0 otherwise.
    var code: Int = 0

    var description: String {
        let path = url.host == "bow.test" ? url.path : url.absoluteString
        return code == 0 ? "\(kind.rawValue) \(path)" : "\(kind.rawValue) \(path) \(code)"
    }
}

/// A failed e2e step, with a message for its FAIL line.
struct E2EError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
