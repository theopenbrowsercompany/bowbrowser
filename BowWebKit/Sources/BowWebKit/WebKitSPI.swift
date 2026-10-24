import AppKit
import ObjectiveC
import WebKit

// The only file in Bow that names a private WebKit selector, delegate callback, KVC key, class or C symbol
// (`make guards` refuses one anywhere else in BowWebKit). Every entry has a kind, which says how it is guarded, and
// a fallback, which is what Bow does when a WebKit release drops it:
// - a private method is checked with `responds(to:)` before every call, and each call wrapper returns false or nil
//   when it is absent;
// - a private delegate callback is one WebKit calls on Bow's object, so it cannot be checked on WebKit's side
//   before use; its presence test reads WebKit's private protocol where WebKit registers one at run time, and the
//   slice that relies on it adds a test that WebKit really calls it;
// - a private C function is looked up with `dlsym` and skipped when absent.
// SPIPresenceTests checks every entry on the running macOS.

@MainActor
enum WebKitSPI {
    /// How a private name is guarded.
    enum Kind: String, Sendable {
        /// A method on a WebKit class, checked with `responds(to:)` before each call.
        case method = "responds(to:)"
        /// A delegate callback WebKit calls on Bow's object, declared in WebKit's private delegate protocol.
        case callback = "callback test"
        /// A C function, looked up with `dlsym`.
        case cFunction = "dlsym"
    }

    /// Who a private method belongs to.
    enum Owner: String, Sendable {
        case webView = "WKWebView"
        case preferences = "WKPreferences"
        case inspector = "_WKInspector"
        case navigationAction = "WKNavigationAction"

        var type: AnyClass? {
            switch self {
            case .webView: WKWebView.self
            case .preferences: WKPreferences.self
            case .navigationAction: WKNavigationAction.self
            case .inspector: NSClassFromString(rawValue)
            }
        }
    }

    struct Entry: Sendable {
        /// The selector or symbol, exactly as WebKit names it.
        var name: String
        var kind: Kind
        /// The class a method is on, or the private protocol a callback is declared in.
        var owner: String
        /// What Bow uses it for.
        var use: String
        /// What Bow does when it is absent.
        var fallback: String
        /// False for an entry kept as information only (a side question, a fallback): its absence is no failure.
        var required = true
        /// For a callback: false when WebKit does not register its private protocol at run time (no WebKit class
        /// adopts `_WKFindDelegate`), so the protocol cannot be read and the callback test of the slice that uses
        /// it is its only check.
        var protocolReadable = true

        var selector: Selector { Selector(name) }
    }

    // MARK: Private methods

    static let findString = Selector(("_findString:options:maxCount:"))
    static let countStringMatches = Selector(("_countStringMatches:options:maxCount:"))
    static let setFindDelegate = Selector(("_setFindDelegate:"))
    static let hideFindUI = Selector(("_hideFindUI"))
    static let isPlayingAudio = Selector(("_isPlayingAudio"))
    static let mediaMutedState = Selector(("_mediaMutedState"))
    static let setPageMuted = Selector(("_setPageMuted:"))
    static let killWebContentProcess = Selector(("_killWebContentProcess"))
    static let inspector = Selector(("_inspector"))
    static let setInspectorAttachmentView = Selector(("_setInspectorAttachmentView:"))
    static let inspectorShow = Selector(("show"))
    // From a string: a public `close` exists, so Selector(("close")) draws a #selector warning.
    static let inspectorClose = NSSelectorFromString("close")
    static let inspectorIsVisible = Selector(("isVisible"))
    static let setDeveloperExtras = Selector(("_setDeveloperExtrasEnabled:"))
    static let setMockCaptureDevices = Selector(("_setMockCaptureDevicesEnabled:"))
    static let setWindowOcclusionDetection = Selector(("_setWindowOcclusionDetectionEnabled:"))
    static let afterMouseEvents = Selector(("_doAfterProcessingAllPendingMouseEvents:"))
    static let afterPresentationUpdate = Selector(("_doAfterNextPresentationUpdate:"))
    static let webProcessIdentifier = Selector(("_webProcessIdentifier"))
    static let tryClose = Selector(("_tryClose"))
    static let sessionStateData = Selector(("_sessionStateData"))
    static let actionIsRedirect = Selector(("_isRedirect"))

    nonisolated static let methods: [Entry] = [
        Entry(
            name: "_findString:options:maxCount:", kind: .method, owner: Owner.webView.rawValue,
            use: "find: step through matches, with the index", fallback: "public find(_:configuration:), no count"),
        Entry(
            name: "_countStringMatches:options:maxCount:", kind: .method, owner: Owner.webView.rawValue,
            use: "find: the match count", fallback: "public find(_:configuration:), no count"),
        Entry(
            name: "_setFindDelegate:", kind: .method, owner: Owner.webView.rawValue,
            use: "find: receive the count and index callbacks", fallback: "no count"),
        Entry(
            name: "_hideFindUI", kind: .method, owner: Owner.webView.rawValue,
            use: "find: clear WebKit's find highlight", fallback: "no-op"),
        Entry(
            name: "_isPlayingAudio", kind: .method, owner: Owner.webView.rawValue,
            use: "audible tab indicator", fallback: "script media events"),
        Entry(
            name: "_mediaMutedState", kind: .method, owner: Owner.webView.rawValue,
            use: "muted tab indicator", fallback: "Bow's own muted flag"),
        Entry(
            name: "_setPageMuted:", kind: .method, owner: Owner.webView.rawValue, use: "mute a tab",
            fallback: "script mute of every media element"),
        Entry(
            name: "_killWebContentProcess", kind: .method, owner: Owner.webView.rawValue,
            use: "end a hung page's process, and the e2e crash check", fallback: "no hang recovery"),
        Entry(
            name: "_inspector", kind: .method, owner: Owner.webView.rawValue, use: "Web Inspector in the window",
            fallback: "isInspectable with Safari's Develop menu"),
        Entry(
            name: "_setInspectorAttachmentView:", kind: .method, owner: Owner.webView.rawValue,
            use: "Web Inspector docked beside the page", fallback: "the inspector in its own window"),
        Entry(
            name: "show", kind: .method, owner: Owner.inspector.rawValue, use: "open Web Inspector",
            fallback: "isInspectable with Safari's Develop menu"),
        Entry(
            name: "close", kind: .method, owner: Owner.inspector.rawValue, use: "close Web Inspector",
            fallback: "the person closes it"),
        Entry(
            name: "isVisible", kind: .method, owner: Owner.inspector.rawValue,
            use: "whether Web Inspector is open, closed by Bow or by its own close button",
            fallback: "the inspector reads as closed"),
        Entry(
            name: "_setDeveloperExtrasEnabled:", kind: .method, owner: Owner.preferences.rawValue,
            use: "Inspect Element in the context menu", fallback: "isInspectable"),
        Entry(
            name: "_setMockCaptureDevicesEnabled:", kind: .method, owner: Owner.preferences.rawValue,
            use: "tests: mock camera and microphone",
            fallback: "none in tests: skip the check rather than use a real device"),
        Entry(
            name: "_setWindowOcclusionDetectionEnabled:", kind: .method, owner: Owner.webView.rawValue,
            use: "tests: pages in off screen windows count as visible", fallback: "no-op"),
        Entry(
            name: "_doAfterProcessingAllPendingMouseEvents:", kind: .method, owner: Owner.webView.rawValue,
            use: "tests: wait until WebKit handled the mouse events sent", fallback: "poll the page"),
        Entry(
            name: "_doAfterNextPresentationUpdate:", kind: .method, owner: Owner.webView.rawValue,
            use: "tests: wait for a paint", fallback: "poll the page"),
        Entry(
            name: "_webProcessIdentifier", kind: .method, owner: Owner.webView.rawValue,
            use: "per tab memory for unloading", fallback: "unload by idle time and memory pressure only"),
        Entry(
            name: "_tryClose", kind: .method, owner: Owner.webView.rawValue,
            use: "information: close a tab after its leave prompt", fallback: "close without asking the page",
            required: false),
        Entry(
            name: "_sessionStateData", kind: .method, owner: Owner.webView.rawValue,
            use: "information: beside interactionState", fallback: "public interactionState", required: false),
        Entry(
            name: "_isRedirect", kind: .method, owner: Owner.navigationAction.rawValue,
            use: "a policy ask for a server redirect (EngineNavigation.isRedirect)",
            fallback: "a redirect asks the policy as a new navigation"),
    ]

    // MARK: Private delegate callbacks

    /// A private callback, its selector and the private protocol WebKit declares it in.
    enum Callback: String, CaseIterable, Sendable {
        case didCountMatches = "_webView:didCountMatches:forString:"
        case didFindMatches = "_webView:didFindMatches:forString:withMatchIndex:"
        case didFailToFind = "_webView:didFailToFindString:"
        case mouseDidMoveOverElement = "_webView:mouseDidMoveOverElement:withFlags:userInfo:"
        case beforeUnloadPanel = "_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:"
        case queryPermission = "_webView:queryPermission:forOrigin:completionHandler:"
        case processTerminated = "_webView:webContentProcessDidTerminateWithReason:"
        case becameUnresponsive = "_webViewWebProcessDidBecomeUnresponsive:"
        case becameResponsive = "_webViewWebProcessDidBecomeResponsive:"

        var selector: Selector { Selector(rawValue) }

        var entry: Entry {
            switch self {
            case .didCountMatches:
                Entry(
                    name: rawValue, kind: .callback, owner: "_WKFindDelegate", use: "find: the match count",
                    fallback: "no count", protocolReadable: false)
            case .didFindMatches:
                Entry(
                    name: rawValue, kind: .callback, owner: "_WKFindDelegate",
                    use: "find: count and index while stepping", fallback: "no count", protocolReadable: false)
            case .didFailToFind:
                Entry(
                    name: rawValue, kind: .callback, owner: "_WKFindDelegate", use: "find: no match",
                    fallback: "a count of 0 from didCountMatches", protocolReadable: false)
            case .mouseDidMoveOverElement:
                Entry(
                    name: rawValue, kind: .callback, owner: "WKUIDelegatePrivate",
                    use: "the link address under the pointer", fallback: "a script hover listener")
            case .beforeUnloadPanel:
                Entry(
                    name: rawValue, kind: .callback, owner: "WKUIDelegatePrivate",
                    use: "information: the leave prompt", fallback: "no leave prompt", required: false)
            case .queryPermission:
                Entry(
                    name: rawValue, kind: .callback, owner: "WKUIDelegatePrivate",
                    use: "information: navigator.permissions.query from Bow's store", fallback: "WebKit's own answer",
                    required: false)
            case .processTerminated:
                Entry(
                    name: rawValue, kind: .callback, owner: "WKNavigationDelegatePrivate",
                    use: "why a page's process ended", fallback: "webViewWebContentProcessDidTerminate, reason other")
            case .becameUnresponsive:
                Entry(
                    name: rawValue, kind: .callback, owner: "WKNavigationDelegatePrivate", use: "a hung page",
                    fallback: "no hang detection")
            case .becameResponsive:
                Entry(
                    name: rawValue, kind: .callback, owner: "WKNavigationDelegatePrivate",
                    use: "a hung page recovered", fallback: "no hang detection")
            }
        }
    }

    nonisolated static var callbacks: [Entry] { Callback.allCases.map(\.entry) }

    // MARK: Presence

    /// Whether a method entry's class answers its selector, or a callback entry's private protocol declares it.
    static func isPresent(_ entry: Entry) -> Bool {
        switch entry.kind {
        case .method:
            guard let type = Owner(rawValue: entry.owner)?.type else { return false }
            return has(entry.selector, on: type)
        case .callback:
            return protocolDeclares(entry.owner, entry.selector)
        case .cFunction:
            return symbol(entry.name) != nil
        }
    }

    static func has(_ selector: Selector, on type: AnyClass) -> Bool {
        type.instancesRespond(to: selector)
    }

    /// Whether the Objective-C protocol named `name` declares `selector`, as an optional or required instance method.
    static func protocolDeclares(_ name: String, _ selector: Selector) -> Bool {
        guard let proto = objc_getProtocol(name) else { return false }
        for required in [false, true] {
            if protocol_getMethodDescription(proto, selector, required, true).name != nil { return true }
        }
        return false
    }

    /// A C function or variable WebKit exports, or nil.
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
    }

    // MARK: Calls

    /// `_WKFindOptions` bits (WebKit's `_WKFindOptions.h`).
    struct FindOptions: OptionSet, Sendable {
        let rawValue: UInt
        static let caseInsensitive = FindOptions(rawValue: 1 << 0)
        static let backwards = FindOptions(rawValue: 1 << 3)
        static let wrapAround = FindOptions(rawValue: 1 << 4)
        static let showOverlay = FindOptions(rawValue: 1 << 5)
        static let showFindIndicator = FindOptions(rawValue: 1 << 6)
        static let showHighlight = FindOptions(rawValue: 1 << 7)
        static let noIndexChange = FindOptions(rawValue: 1 << 8)
        static let determineMatchIndex = FindOptions(rawValue: 1 << 9)
    }

    /// Finds `string`, reporting through the find delegate. False when absent.
    @discardableResult
    static func find(_ webView: WKWebView, _ string: String, options: FindOptions, maxCount: UInt) -> Bool {
        callFind(webView, findString, string, options.rawValue, maxCount)
    }

    /// Counts matches of `string`, reporting through the find delegate. False when absent.
    @discardableResult
    static func countMatches(_ webView: WKWebView, _ string: String, options: FindOptions, maxCount: UInt) -> Bool {
        callFind(webView, countStringMatches, string, options.rawValue, maxCount)
    }

    private static func callFind(_ webView: WKWebView, _ selector: Selector, _ string: String, _ a: UInt, _ b: UInt)
        -> Bool
    {
        guard webView.responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        unsafeBitCast(webView.method(for: selector), to: Fn.self)(webView, selector, string as NSString, a, b)
        return true
    }

    /// Sets the private find delegate (WebKit keeps it weakly). False when absent.
    @discardableResult
    static func setFindDelegate(_ webView: WKWebView, _ delegate: SPIFindDelegate?) -> Bool {
        guard webView.responds(to: setFindDelegate) else { return false }
        webView.perform(setFindDelegate, with: delegate)
        return true
    }

    /// Clears WebKit's find highlight; a no-op when absent.
    static func hideFind(_ webView: WKWebView) {
        guard webView.responds(to: hideFindUI) else { return }
        webView.perform(hideFindUI)
    }

    /// Whether the page is playing sound, or nil when absent.
    static func playingAudio(_ webView: WKWebView) -> Bool? {
        guard webView.responds(to: isPlayingAudio) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(webView.method(for: isPlayingAudio), to: Fn.self)(webView, isPlayingAudio)
    }

    /// `_WKMediaMutedState` bits (WebKit's `WKWebViewPrivate.h`).
    struct MediaMutedState: OptionSet, Sendable {
        let rawValue: UInt
        static let audio = MediaMutedState(rawValue: 1 << 0)
        static let captureDevices = MediaMutedState(rawValue: 1 << 1)
        static let screenCapture = MediaMutedState(rawValue: 1 << 2)
    }

    /// What the page has muted, or nil when absent.
    static func mutedState(_ webView: WKWebView) -> MediaMutedState? {
        guard webView.responds(to: mediaMutedState) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt
        return MediaMutedState(
            rawValue: unsafeBitCast(webView.method(for: mediaMutedState), to: Fn.self)(webView, mediaMutedState))
    }

    /// Mutes what `state` names and unmutes the rest. False when absent.
    @discardableResult
    static func setMuted(_ webView: WKWebView, _ state: MediaMutedState) -> Bool {
        guard webView.responds(to: setPageMuted) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: setPageMuted), to: Fn.self)(webView, setPageMuted, state.rawValue)
        return true
    }

    /// Ends the page's web content process. False when absent.
    @discardableResult
    static func killContentProcess(_ webView: WKWebView) -> Bool {
        guard webView.responds(to: killWebContentProcess) else { return false }
        webView.perform(killWebContentProcess)
        return true
    }

    /// The web view's `_WKInspector`, or nil when absent.
    static func inspectorObject(_ webView: WKWebView) -> NSObject? {
        guard webView.responds(to: inspector) else { return nil }
        return webView.perform(inspector)?.takeUnretainedValue() as? NSObject
    }

    /// Opens or closes Web Inspector. False when absent.
    @discardableResult
    static func setInspectorShown(_ webView: WKWebView, _ shown: Bool) -> Bool {
        let selector = shown ? inspectorShow : inspectorClose
        guard let object = inspectorObject(webView), object.responds(to: selector) else { return false }
        object.perform(selector)
        return true
    }

    /// Whether Web Inspector is open, or nil when absent.
    static func inspectorVisible(_ webView: WKWebView) -> Bool? {
        guard let object = inspectorObject(webView), object.responds(to: inspectorIsVisible) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: inspectorIsVisible), to: Fn.self)(object, inspectorIsVisible)
    }

    /// Docks Web Inspector in `view` (nil for its default place). False when absent.
    @discardableResult
    static func setInspectorAttachment(_ webView: WKWebView, _ view: NSView?) -> Bool {
        guard webView.responds(to: setInspectorAttachmentView) else { return false }
        webView.perform(setInspectorAttachmentView, with: view)
        return true
    }

    /// Turns on Inspect Element in the page's context menu. False when absent.
    @discardableResult
    static func setDeveloperExtrasEnabled(_ preferences: WKPreferences, _ on: Bool) -> Bool {
        callBool(preferences, setDeveloperExtras, on)
    }

    /// Turns WebKit's mock capture devices on, so no real camera or microphone is used. False when absent.
    @discardableResult
    static func setMockCaptureDevicesEnabled(_ preferences: WKPreferences, _ on: Bool) -> Bool {
        callBool(preferences, setMockCaptureDevices, on)
    }

    /// Off: a page in a window off every screen still counts as visible, so WebKit does not throttle it. False when
    /// absent.
    @discardableResult
    static func setWindowOcclusionDetectionEnabled(_ webView: WKWebView, _ on: Bool) -> Bool {
        callBool(webView, setWindowOcclusionDetection, on)
    }

    private static func callBool(_ object: NSObject, _ selector: Selector, _ on: Bool) -> Bool {
        guard object.responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Fn.self)(object, selector, on)
        return true
    }

    /// Waits until WebKit has handled every mouse event sent so far. False at once when absent, and false after
    /// `timeout` seconds when WebKit never calls back (its process ended, or the view left its window).
    static func afterPendingMouseEvents(_ webView: WKWebView, timeout: TimeInterval = 5) async -> Bool {
        await afterBlock(webView, afterMouseEvents, timeout: timeout)
    }

    /// Waits for WebKit's next presentation update. False at once when absent, and false after `timeout` seconds
    /// when WebKit never calls back.
    static func afterNextPresentationUpdate(_ webView: WKWebView, timeout: TimeInterval = 5) async -> Bool {
        await afterBlock(webView, afterPresentationUpdate, timeout: timeout)
    }

    private static func afterBlock(_ webView: WKWebView, _ selector: Selector, timeout: TimeInterval) async -> Bool {
        guard webView.responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, @convention(block) @escaping () -> Void) -> Void
        let fn = unsafeBitCast(webView.method(for: selector), to: Fn.self)
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(done)
            fn(webView, selector) { MainActor.assumeIsolated { once.resume(true) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { once.resume(false) }
            }
        }
    }

    /// Resumes a continuation with the first answer only: WebKit's callback or the timeout, whichever comes first.
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// The page's web content process, or nil when absent or not running.
    static func processIdentifier(_ webView: WKWebView) -> pid_t? {
        guard webView.responds(to: webProcessIdentifier) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> pid_t
        let pid = unsafeBitCast(webView.method(for: webProcessIdentifier), to: Fn.self)(webView, webProcessIdentifier)
        return pid > 0 ? pid : nil
    }

    /// Asks the page to close, running its beforeunload handler. False when absent.
    @discardableResult
    static func tryCloseWebView(_ webView: WKWebView) -> Bool {
        guard webView.responds(to: tryClose) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        _ = unsafeBitCast(webView.method(for: tryClose), to: Fn.self)(webView, tryClose)
        return true
    }

    /// Whether WebKit asks about `action` for a server redirect of a navigation under way, or nil when absent.
    static func isRedirect(_ action: WKNavigationAction) -> Bool? {
        guard action.responds(to: actionIsRedirect) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(action.method(for: actionIsRedirect), to: Fn.self)(action, actionIsRedirect)
    }

    /// WebKit's private session state, beside the public `interactionState`. Nil when absent.
    static func sessionState(_ webView: WKWebView) -> Data? {
        guard webView.responds(to: sessionStateData) else { return nil }
        return webView.perform(sessionStateData)?.takeUnretainedValue() as? Data
    }
}

/// The private find delegate (`_WKFindDelegate`), handing its callbacks to closures so no other file names them.
/// WebKit keeps it weakly: its owner holds it.
@MainActor
final class SPIFindDelegate: NSObject {
    /// (match count, string).
    var onCount: ((UInt, String) -> Void)?
    /// (match count, string, index of the active match).
    var onFind: ((UInt, String, Int) -> Void)?
    var onFail: ((String) -> Void)?

    @objc(_webView:didCountMatches:forString:)
    nonisolated func webView(_ webView: WKWebView, didCountMatches matches: UInt, forString string: String) {
        MainActor.assumeIsolated { onCount?(matches, string) }
    }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    nonisolated func webView(
        _ webView: WKWebView, didFindMatches matches: UInt, forString string: String, withMatchIndex index: Int
    ) {
        MainActor.assumeIsolated { onFind?(matches, string, index) }
    }

    @objc(_webView:didFailToFindString:)
    nonisolated func webView(_ webView: WKWebView, didFailToFindString string: String) {
        MainActor.assumeIsolated { onFail?(string) }
    }
}

/// Why WebKit ended a page's process (`_WKProcessTerminationReason`; the raw values follow WebKit's header order,
/// inference from WebKit's open source).
enum SPIProcessTerminationReason: Int, Sendable {
    case exceededMemoryLimit = 0
    case exceededCPULimit = 1
    case requestedByClient = 2
    case crash = 3
}

/// The base of the object Bow sets as a web view's navigation and UI delegate: it receives WebKit's private
/// delegate callbacks and hands them to closures, so no other file names them.
///
/// WebKit asks its delegate which methods it answers once, when the delegate is set, and a private callback it
/// finds can replace a public one (the termination reason one replaces `webViewWebContentProcessDidTerminate`).
/// So the base answers only the callbacks given at init (`responds(to:)` says no to the rest), and those must be
/// chosen before the object becomes a delegate.
@MainActor
class SPIDelegateBase: NSObject {
    /// The private callbacks this object answers.
    nonisolated let privateCallbacks: Set<WebKitSPI.Callback>

    /// The link under the pointer, or nil once it has left every link (`mouseDidMoveOverElement`).
    var onHoverLink: ((URL?, NSEvent.ModifierFlags) -> Void)?
    /// The leave prompt: the page's message, and the answer to hand on (true leaves) (`beforeUnloadPanel`).
    var onBeforeUnload: ((String, @escaping @Sendable (Bool) -> Void) -> Void)?
    /// `navigator.permissions.query`: (permission name, origin) to an answer, a `WKPermissionDecision` raw value
    /// (inference: 0 prompt, 1 grant, 2 deny) (`queryPermission`).
    var onQueryPermission: ((String, String, @escaping @Sendable (Int) -> Void) -> Void)?
    /// The page's process ended, with WebKit's reason; nil for a raw value Bow does not know (`processTerminated`).
    var onProcessTerminated: ((SPIProcessTerminationReason?) -> Void)?
    /// The page stopped answering (true) or answers again (false) (`becameUnresponsive`, `becameResponsive`).
    var onResponsiveness: ((Bool) -> Void)?

    init(privateCallbacks: Set<WebKitSPI.Callback>) {
        self.privateCallbacks = privateCallbacks
        super.init()
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if let callback = WebKitSPI.Callback(rawValue: NSStringFromSelector(selector)) {
            return privateCallbacks.contains(callback)
        }
        return super.responds(to: selector)
    }

    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    nonisolated func spiMouseDidMove(
        _ webView: WKWebView, mouseDidMoveOverElement element: NSObject, withFlags flags: NSEvent.ModifierFlags,
        userInfo: AnyObject?
    ) {
        // `_WKHitTestResult.absoluteLinkURL`, checked first: reading a key WebKit dropped would raise.
        let link =
            element.responds(to: NSSelectorFromString("absoluteLinkURL"))
            ? element.value(forKey: "absoluteLinkURL") as? URL : nil
        MainActor.assumeIsolated { onHoverLink?(link, flags) }
    }

    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    nonisolated func spiBeforeUnload(
        _ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let onBeforeUnload else { return completionHandler(true) }
            onBeforeUnload(message, completionHandler)
        }
    }

    @objc(_webView:queryPermission:forOrigin:completionHandler:)
    nonisolated func spiQueryPermission(
        _ webView: WKWebView, queryPermission name: String, forOrigin origin: WKSecurityOrigin,
        completionHandler: @escaping @Sendable (Int) -> Void
    ) {
        MainActor.assumeIsolated {
            let originText = "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
            guard let onQueryPermission else { return completionHandler(0) }
            onQueryPermission(name, originText, completionHandler)
        }
    }

    @objc(_webView:webContentProcessDidTerminateWithReason:)
    nonisolated func spiProcessTerminated(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        MainActor.assumeIsolated { onProcessTerminated?(SPIProcessTerminationReason(rawValue: reason)) }
    }

    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    nonisolated func spiBecameUnresponsive(_ webView: WKWebView) {
        MainActor.assumeIsolated { onResponsiveness?(true) }
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    nonisolated func spiBecameResponsive(_ webView: WKWebView) {
        MainActor.assumeIsolated { onResponsiveness?(false) }
    }
}
