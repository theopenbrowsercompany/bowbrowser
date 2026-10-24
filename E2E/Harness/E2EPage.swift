import AppKit

// The small protocol e2e tests use to drive the app. Tests never touch engine or window types directly:
// E2EAppAdapter.swift implements these on today's bridge, so reshaping the bridge swaps that one file.

/// The app as a test sees it.
@MainActor
protocol E2EApp: AnyObject {
    /// Opens a browser window on `url`, off screen and never key, in `profile`, and returns its page (the window's
    /// first tab). Throws when the window would be visible on a screen or the app could take focus, and throws an
    /// error with reason `.profileTaken` when a new profile's ID is taken.
    /// The runner closes every window a test opened once the test ends, so tests need not close their own.
    /// Once a test has ended, every action of its app and pages (except reading state) throws, so work a timed-out
    /// step left running cannot drive the app any further.
    func openWindow(at url: URL, profile: E2EWindowProfile) async throws -> any E2EPage
    /// Opens `url` in a new tab of the window `page` is in, selected unless `select` is false.
    func openTab(at url: URL, besides page: any E2EPage, select: Bool) throws -> any E2EPage
    /// Selects the tab `page` is in, showing it in its window.
    func select(_ page: any E2EPage) throws
    /// Closes the tab `page` is in, running its page's beforeunload handler. Returns true once the tab has closed,
    /// and false when the page's leave prompt was answered with stay (see `E2EPage.leavePromptAnswer`).
    func closeTab(_ page: any E2EPage) async throws -> Bool
    /// Closes the window `page` is in the way its close button does, and returns once the window has closed.
    func closeWindow(of page: any E2EPage) async throws
    /// Clicks `button` in the toolbar of the window `page` is in. Throws when the button is disabled.
    func click(_ button: E2EToolbarButton, in page: any E2EPage) throws
    /// The state of `button` in the toolbar of the window `page` is in.
    func toolbarButton(_ button: E2EToolbarButton, in page: any E2EPage) throws -> E2EToolbarButtonState
    /// Sends `shortcut` to the window `page` is in the way pressing its keys does: through the app's menu, to the
    /// menu item that has the shortcut. Throws when no menu item has it or the item is disabled.
    func press(_ shortcut: E2EShortcut, in page: any E2EPage) throws
    /// Quits the way the app's Quit menu item does.
    func quit()

    /// Every row of the downloads window, newest first. The window opens off screen on first use.
    func downloads() async throws -> [E2EDownload]
    /// Clicks one of a download's buttons in the downloads window. Throws when the button is hidden.
    func press(_ button: E2EDownload.Button, of download: E2EDownload) async throws
}

/// One row of the downloads window.
struct E2EDownload: Equatable {
    enum Button {
        /// Pause while running, resume while paused or failed.
        case pauseOrResume
        /// Cancel while running or paused, clear once finished.
        case cancelOrClear
    }

    /// Stable for the life of the download.
    var id: String
    /// The name the row shows.
    var fileName: String
    /// `inProgress`, `paused`, `complete`, `cancelled`, `interrupted` or `unknown`.
    var state: String
    /// The status line the row shows under the name.
    var status: String
    var receivedBytes: Int64
    /// The file the download writes, once chosen.
    var path: URL?
}

extension E2EApp {
    /// Opens a window in the test's own fresh in-memory profile (see `E2EWindowProfile.test`).
    func openWindow(at url: URL) async throws -> any E2EPage {
        try await openWindow(at: url, profile: .test)
    }

    /// Opens a window in a profile created for it.
    func openWindow(at url: URL, newProfile profile: E2EProfile) async throws -> any E2EPage {
        try await openWindow(at: url, profile: .new(profile))
    }
}

/// The profile a window opens in.
enum E2EWindowProfile {
    /// The running test's own profile: in memory, made fresh for each test and shared by that test's windows, so
    /// no storage or permission leaks from one test to the next. The default.
    case test
    /// The app's default profile, shared by every test that asks for it for the whole run.
    case appDefault
    /// A profile created for this window: on disk when persistent, in memory otherwise.
    case new(E2EProfile)
}

/// A navigation button in a browser window's toolbar.
enum E2EToolbarButton: String {
    case back, forward
    /// Reload while the page is idle, stop while it loads.
    case reload
}

/// What a toolbar button shows: whether it can be clicked, and its label (the reload button reads "Reload" or
/// "Stop").
struct E2EToolbarButtonState: Equatable, CustomStringConvertible {
    var isEnabled: Bool
    var label: String

    var description: String { "\(label)(\(isEnabled ? "on" : "off"))" }
}

/// An app keyboard shortcut: Command with a key.
enum E2EShortcut: String {
    case back = "["
    case forward = "]"
    case reload = "r"
    case stop = "."

    /// The key pressed with Command, as a menu item's key equivalent.
    var key: String { rawValue }
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
    /// Starts loading `url` in the page's tab, the way the address bar does. Throws once the page's test has ended.
    func load(_ url: URL) throws
    /// Every main frame navigation event the page's tab reported, in order, starting when the window opens.
    var navigationEvents: [E2ENavigationEvent] { get }
    /// Asked before every main frame navigation and redirect, with its URL: false cancels it, and the canceled
    /// navigation reports no events. Nil allows every navigation.
    var navigationPolicy: ((URL) -> Bool)? { get set }
    /// How the page's "leave this site?" prompt is answered when its beforeunload handler asks on close: true
    /// leaves (the default, so quitting never waits on a prompt), false stays. Reload prompts always go ahead.
    /// No prompt ever shows on screen.
    var leavePromptAnswer: Bool { get set }
    /// How many leave prompts (not counting reload prompts) the page's tab has asked so far.
    var leavePrompts: Int { get }
    /// Opens the find bar of the page's window the way Edit > Find (Cmd+F) does, and returns it.
    /// Throws when the menu item is missing or the bar does not show.
    func openFindBar() throws -> any E2EFindBar
    /// The permission prompt the page's window shows for this page now, or nil.
    var permissionPrompt: E2EPermissionPrompt? { get }
    /// The view that shows the page's web content, for screenshots; nil while another tab of its window is shown
    /// and once it is gone.
    var contentView: NSView? { get }

    // The page driver: the only way tests and harness helpers reach into the page. These name no engine, so each
    // engine's adapter implements them its own way (today over Chromium's DevTools protocol, in
    // E2EAppAdapter+PageDriver.swift), and the helpers built on them (E2EInput.swift, E2EScreenshot.swift) stay the
    // same. Every one throws once the page's test has ended, except `screenshot`, which the runner still takes then.

    /// Evaluates the JavaScript `expression` in the page and returns its value as JSON types (nil for undefined or
    /// null). Each of `arguments` (JSON values, keyed by valid JavaScript identifiers) is bound to a constant of its
    /// name that the expression can read. A promise is awaited, so an expression can wait on a page state change
    /// without fixed sleeps. With `userGesture`, the page treats the expression as run from a person's click (it may
    /// open a popup). Throws with the page's exception text when the expression throws.
    func evaluate(_ expression: String, arguments: [String: Any], userGesture: Bool) async throws -> Any?
    /// The page's visible web content, as the engine paints it.
    func screenshot() async throws -> NSImage
    /// Makes the page behave as if its window were focused. An e2e window never becomes key, so without this the
    /// page has no focus: `document.hasFocus()` is false and focus events do not fire. The input helpers call it
    /// themselves, so tests need not.
    func emulateFocus() async throws
    /// Sends one mouse event to the page as real user input, returning once the page has handled it.
    func dispatchMouse(_ event: E2EMouseEvent) async throws
    /// Sends one key event to the page's focused element as real user input, so the app sees it before the page
    /// (`EngineTabDelegate.handleKeyBeforePage`), returning once the page has handled it.
    func dispatchKey(_ event: E2EKeyEvent) async throws
    /// Inserts `text` into the focused element, the way text arrives from a keyboard or an input method.
    func insertText(_ text: String) async throws
    /// Ends the page's renderer as a crash would, and returns without waiting for it to end.
    func crash() throws
}

extension E2EPage {
    /// Evaluates `expression` in the page with no arguments and no user gesture (see
    /// `evaluate(_:arguments:userGesture:)`).
    func evaluate(_ expression: String) async throws -> Any? {
        try await evaluate(expression, arguments: [:], userGesture: false)
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

/// A permission prompt on screen (off screen, in an e2e run) for one page.
@MainActor
struct E2EPermissionPrompt {
    /// What the page asked for, by BowCore's names (camera, microphone, geolocation and others).
    var kinds: Set<String>
    /// The prompt's text.
    var message: String
    /// The prompt's frame in screen coordinates.
    var frame: NSRect
    /// Presses Allow (true) or Block (false), as a click on the button does. Throws once the page's test has ended.
    var answer: (Bool) throws -> Void
}

extension E2EPage {
    /// Waits until the page's permission prompt shows and returns it. The caller's step timeout bounds the wait.
    func waitForPermissionPrompt() async throws -> E2EPermissionPrompt {
        while true {
            if let prompt = permissionPrompt { return prompt }
            if isClosed { throw E2EError("the tab closed") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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
    /// The HTTP status for finish, 0 otherwise.
    var code: Int = 0
    /// For fail, the name of the failure's reason (BowCore's `NavigationError.Reason`, for example `cannotConnect`);
    /// empty otherwise.
    var failure: String = ""

    var description: String {
        let path = url.host == "bow.test" ? url.path : url.absoluteString
        let result = failure.isEmpty ? (code == 0 ? "" : " \(code)") : " \(failure)"
        return "\(kind.rawValue) \(path)\(result)"
    }
}

/// A failed e2e step, with a message for its FAIL line and, for failures a test tells apart, a reason.
struct E2EError: Error, CustomStringConvertible {
    enum Reason: Equatable {
        /// `openWindow` was asked for a new profile whose ID another profile has (IDs are compared ignoring case).
        case profileTaken
        /// A step or test ran past its limit.
        case timeout
        /// An app or page action came from a test that had already ended (work a timed-out step left running).
        case testEnded
    }

    let description: String
    let reason: Reason?

    init(_ description: String, reason: Reason? = nil) {
        self.description = description
        self.reason = reason
    }
}
