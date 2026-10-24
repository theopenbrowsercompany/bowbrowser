import AppKit

/// Watches the AppKit windows a test creates, for the runner's `e2e.isolation` check: none may ever show on a screen,
/// or a run could flash on the maintainer's display.
///
/// Windows alive when the watch starts are the baseline, held weakly so the watch keeps nothing alive; every other
/// window counts as the test's, hidden windows, sheets and panels included. The runner's own windows count too: they
/// are off every screen by design, so none is ever exempt.
@MainActor
final class E2EWindowWatch {
    /// Window classes exempt from the check: windows AppKit makes and places itself, which a test cannot keep off a
    /// screen. Exact class names only, never a prefix or a filter, each with its reason. None is needed today.
    static let exemptClasses: [String: String] = [:]

    private struct Weak {
        weak var window: NSWindow?
    }

    private let baseline: [Weak]
    private var observers: [NSObjectProtocol] = []
    /// The test windows seen on a screen, once each, in the order they were seen.
    private var shown: [String] = []
    private var shownWindows = Set<ObjectIdentifier>()

    /// Starts watching: the windows alive now are the baseline, and from now on every window move, resize, screen
    /// change or occlusion change is checked for a test window showing on a screen. A broken rule (`selfCheckFailure`)
    /// is recorded first.
    init() {
        baseline = NSApp.windows.map { Weak(window: $0) }
        if let broken = Self.selfCheckFailure { shown.append(broken) }
        let names = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        observers = names.map { name in
            // Delivered on the posting thread, so a window change is checked before the next one; AppKit posts these
            // on the main thread, and a post from any other thread is ignored rather than trusted.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard Thread.isMainThread, let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.check(window) }
            }
        }
    }

    /// Checks every test window now. The runner calls it once the test ends, before it closes the test's windows,
    /// for a window that reached a screen without a notification.
    func checkAll() {
        for window in NSApp.windows { check(window) }
    }

    /// Stops watching and returns each test window seen on a screen, or nil. The runner calls it after closing the
    /// test's windows, so what closing them did is checked too.
    func finish() -> String? {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        return shown.isEmpty ? nil : "windows shown on a screen: " + shown.joined(separator: ", ")
    }

    /// Records `window` when it is a visible test window that `Self.shows` says shows, or could show, on a screen.
    private func check(_ window: NSWindow) {
        guard window.isVisible, !shownWindows.contains(ObjectIdentifier(window)),
            Self.exemptClasses[NSStringFromClass(type(of: window))] == nil,
            !baseline.contains(where: { $0.window === window })
        else { return }
        let reading = Reading(
            frame: window.frame, reportedVisible: window.occlusionState.contains(.visible),
            hiddenFromMissionControl: window.collectionBehavior.contains(.transient), isSheet: window.isSheet)
        guard let why = Self.shows(reading, screens: NSScreen.screens.map(\.frame)) else { return }
        shownWindows.insert(ObjectIdentifier(window))
        var traits: [String] = []
        if window.isSheet { traits.append("sheet") }
        if window is NSPanel { traits.append("panel") }
        let kind = traits.isEmpty ? "" : " (\(traits.joined(separator: ", ")))"
        let server = Self.serverBounds(of: window).map { "; the window server has it at \($0)" } ?? ""
        shown.append(
            "\(NSStringFromClass(type(of: window))) \"\(window.title)\"\(kind) at \(window.frame) (\(why)\(server))")
    }

    /// What the watch reads of a visible window.
    struct Reading {
        var frame: NSRect
        /// The window server says some of the window is drawn on a screen (its occlusion state).
        var reportedVisible: Bool
        /// Mission Control leaves the window out (a transient window).
        var hiddenFromMissionControl: Bool
        /// A sheet, which Mission Control shows only as part of its window, a test window the watch checks too.
        var isSheet: Bool
    }

    /// Why a visible window with `reading` shows on one of `screens`, or could, or nil when it cannot.
    ///
    /// The frame alone is not enough: the window server draws a shadow outside the frame, so a window whose frame
    /// stops a few points short of a screen still puts pixels on it, and only its occlusion state says so. Mission
    /// Control draws every window it shows as a thumbnail on a screen wherever its frame is, which the occlusion state
    /// reports too, but only while Mission Control is open, so a window it would show fails even when it is not.
    static func shows(_ reading: Reading, screens: [NSRect]) -> String? {
        if screens.contains(where: { $0.intersects(reading.frame) }) { return "its frame overlaps a screen" }
        if reading.reportedVisible { return "the window server reports it visible" }
        if !reading.hiddenFromMissionControl, !reading.isSheet { return "Mission Control would show it" }
        return nil
    }

    /// Why `shows` misses a window planted on a screen (never ordered in, only read), or flags one that cannot show;
    /// nil when it is right. Read once per app, it fails `e2e.isolation` in every test when the rule is broken.
    static let selfCheckFailure: String? = {
        let screens = NSScreen.screens.map(\.frame)
        // With no screen attached there is nothing to show on; a made up one still checks the rule.
        let screen = screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offscreen = E2EAppAdapter.windowFrame
        let planted: [(String, Reading, Bool)] = [
            (
                "on a screen",
                Reading(
                    frame: screen.insetBy(dx: 100, dy: 100), reportedVisible: false,
                    hiddenFromMissionControl: true, isSheet: false), true
            ),
            (
                "off screen, reported visible",
                Reading(
                    frame: offscreen, reportedVisible: true,
                    hiddenFromMissionControl: true, isSheet: false), true
            ),
            (
                "off screen, shown by Mission Control",
                Reading(
                    frame: offscreen, reportedVisible: false,
                    hiddenFromMissionControl: false, isSheet: false), true
            ),
            (
                "off screen and hidden",
                Reading(
                    frame: offscreen, reportedVisible: false,
                    hiddenFromMissionControl: true, isSheet: false), false
            ),
        ]
        let wrong = planted.filter { _, reading, expected in
            (shows(reading, screens: screens.isEmpty ? [screen] : screens) != nil) != expected
        }
        guard !wrong.isEmpty else { return nil }
        return "the window watch's rule is wrong for windows planted " + wrong.map(\.0).joined(separator: ", ")
    }()

    /// Where the window server has `window`, in AppKit's screen coordinates, or nil when it does not know it.
    private static func serverBounds(of window: NSWindow) -> NSRect? {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber))
        guard let info = (list as? [[String: Any]])?.first,
            let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        else { return nil }
        // The window server measures from the top left of the main display, AppKit from its bottom left.
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.minX, y: height - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}
