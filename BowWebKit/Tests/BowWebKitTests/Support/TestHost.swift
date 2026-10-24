import AppKit
import WebKit

@testable import BowWebKit

/// An error from the test support, with what it was doing.
struct TestError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Holds an object weakly, to check it was released.
final class WeakBox {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}

/// A window far from every screen, which refuses any move that would bring it near a screen.
///
/// The test process is never active (and `swift test` gives it no app to activate), so AppKit never makes one of
/// its windows key: `makeKey()` alone leaves it not key, as the W1 spike found in an inactive app too. So the window
/// says it is key itself (`reportsKey`, the spike's focus model 2), which is what WebKit reads to give the page
/// focus; the maintainer's focus is never taken.
final class TestWindow: NSWindow {
    /// The window reports itself key. `TestHost.show` sets it on one window at a time.
    var reportsKey = false {
        didSet {
            guard reportsKey != oldValue else { return }
            NotificationCenter.default.post(
                name: reportsKey ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: self)
        }
    }

    override var isKeyWindow: Bool { reportsKey || super.isKeyWindow }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isRestorable: Bool {
        get { false }
        set {}
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(TestHost.kept(frameRect, for: self), display: flag)
    }
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(TestHost.kept(frameRect, for: self), display: displayFlag, animate: animateFlag)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(TestHost.kept(NSRect(origin: point, size: frame.size), for: self).origin)
    }
}

/// The test process as a host for web views. `swift test` runs tests in a helper process with no bundle and no
/// app set up, so the host makes the shared `NSApplication` without activating it, puts every window off screen,
/// and checks no window of the process ever reached a screen.
@MainActor
enum TestHost {
    private static var next = 0
    /// Moves a window tried that would have brought it near a screen, refused.
    private(set) static var refusedMoves: [String] = []

    /// Makes the shared application and starts the isolation monitor. `swift test`'s helper process keeps the
    /// prohibited activation policy on purpose: such a process has no Dock icon or menu bar and cannot be activated,
    /// and pages in its off screen windows still get focus and trusted clicks (checked by HostTests).
    static func start() {
        _ = NSApplication.shared
        IsolationMonitor.start()
    }

    /// A frame far from every screen, a different one for each window.
    static func offscreenFrame(size: NSSize) -> NSRect {
        next += 1
        return NSRect(x: -20_000 - CGFloat(next) * 2_000, y: -20_000, width: size.width, height: size.height)
    }

    /// A borderless window off screen, ordered in without activating the app. Borderless on purpose: AppKit places
    /// a titled window made with an off screen frame on a screen (found by the W1 spike).
    static func window(size: NSSize = NSSize(width: 1000, height: 700)) throws -> TestWindow {
        start()
        let window = TestWindow(
            contentRect: offscreenFrame(size: size), styleMask: [.borderless, .resizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Out of Mission Control, which draws every window of every app, off screen ones too.
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        // Never order in a window that is near a screen: stop the whole test process at once, as the spike does.
        guard !nearScreen(window.frame) else {
            print("FAIL isolation: a test window was made at \(window.frame), near a screen; not shown")
            fflush(stdout)
            exit(3)
        }
        window.orderFrontRegardless()
        return window
    }

    /// Puts `view` in `window`, filling its content view, and makes the window the key one without activating the
    /// app (it reports key before the view joins it, so WebKit sees a key window from the start).
    static func show(_ view: NSView, in window: TestWindow) {
        guard let content = window.contentView else { return }
        for other in NSApp.windows.compactMap({ $0 as? TestWindow }) where other !== window {
            other.reportsKey = false
        }
        window.reportsKey = true
        window.makeKey()
        view.removeFromSuperview()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        window.makeFirstResponder(view)
    }

    /// Empties and closes `window`.
    static func close(_ window: TestWindow) {
        window.reportsKey = false
        for view in window.contentView?.subviews ?? [] { view.removeFromSuperview() }
        window.orderOut(nil)
        window.close()
    }

    /// A web view on `configuration` in its own off screen key window, with occlusion detection off so WebKit does
    /// not throttle a page no screen shows.
    static func webView(_ configuration: WKWebViewConfiguration = TestHost.configuration()) throws -> (
        TestWindow, TestWebView
    ) {
        let window = try window()
        let webView = TestWebView(frame: window.contentView?.bounds ?? .zero, configuration: configuration)
        WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false)
        show(webView, in: window)
        return (window, webView)
    }

    /// A fresh configuration for test web views: media plays without a gesture, since no person clicks (the
    /// spike found muted autoplay needs this), on the store given (non persistent when none).
    static func configuration(store: WKWebsiteDataStore = .nonPersistent()) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    // MARK: Isolation

    /// Whether `window` holds key: AppKit's key window, or, since an inactive process has none, the window's own
    /// `isKeyWindow` (the spike's `holdsKey`).
    static func holdsKey(_ window: NSWindow) -> Bool {
        NSApp.keyWindow.map { $0 === window } ?? window.isKeyWindow
    }

    static func nearScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame.insetBy(dx: -200, dy: -200)) }
    }

    static func kept(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard nearScreen(frame) else { return frame }
        refusedMoves.append("\(frame)")
        let resized = NSRect(origin: window.frame.origin, size: frame.size)
        return nearScreen(resized) ? NSRect(origin: NSPoint(x: -40_000, y: -40_000), size: frame.size) : resized
    }

    /// Windows of this process on some screen right now, from the window server (menus and panels included).
    static func windowsOnScreen() -> [String] {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }
        // Window server bounds are top left based; convert each screen frame.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let displays = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
        var found: [String] = []
        for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == pid {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let onScreen = info[kCGWindowIsOnscreen as String] as? Bool, onScreen
            else { continue }
            let rect = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.width > 0, rect.height > 0, displays.contains(where: { $0.intersects(rect) }) {
                found.append("#\(info[kCGWindowNumber as String] ?? 0)@\(rect)")
            }
        }
        return found
    }
}

/// Watches the window server every 50 ms from the first test window on: any window of the test process on a
/// screen (menus included) is recorded and hidden at once, and the isolation check of every host test fails.
@MainActor
enum IsolationMonitor {
    private static var timer: Timer?
    private(set) static var violations: [String] = []

    static func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func check() {
        let shown = TestHost.windowsOnScreen()
        guard !shown.isEmpty else { return }
        violations.append(contentsOf: shown)
        for window in NSApp.windows where window.isVisible && TestHost.nearScreen(window.frame) {
            window.orderOut(nil)
        }
    }
}

/// The tests' web view: accepts the first click, because the test process is never active, so to AppKit every
/// click is a first click into an inactive app (the W1 spike's finding).
final class TestWebView: WKWebView {
    /// Mouse downs AppKit delivered to the view.
    private(set) var mouseDowns = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDowns += 1
        super.mouseDown(with: event)
    }

    /// Stops loading, drops the delegates and leaves the window, so nothing keeps the web view alive; returns a
    /// weak reference to check it is gone.
    func dispose() -> WeakBox {
        let box = WeakBox(self)
        stopLoading()
        navigationDelegate = nil
        uiDelegate = nil
        removeFromSuperview()
        return box
    }
}
