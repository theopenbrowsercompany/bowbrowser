import AppKit

/// Watches the AppKit windows a test creates, for the runner's `e2e.isolation` check: none may show on a screen, and
/// none may still be alive once the runner has closed the test's windows.
///
/// A window kept alive by a stray reference (a retain cycle in a sheet's controller, a test-local static) stays in
/// `NSApp.windows`, hidden, and confuses later tests that count windows. A window that shows on a screen means a run
/// could flash on the maintainer's display. Windows alive when the watch starts are the baseline, held weakly so the
/// watch keeps nothing alive; every other window counts as the test's.
@MainActor
final class E2EWindowWatch {
    /// Window classes AppKit creates once, when something first needs them, and keeps for the life of the app. The
    /// test that happens to need one first did not leak it. Exact class names only, never a prefix or a filter; each
    /// says why. They are exempt from both checks: AppKit places them, and none of them shows a page.
    static let persistentClasses: [String: String] = [
        // TextInputUI's input source indicator, made the first time a text field takes the keyboard (the find bar,
        // the command bar) and kept for the app's life.
        "TUINSWindow": "AppKit's text input indicator, kept once made",
        // TextInputUI's rounded window behind the same indicator, made and kept along with it.
        "SPRoundedWindow": "AppKit's text input indicator background, kept once made",
    ]

    private struct Weak {
        weak var window: NSWindow?
    }

    private let baseline: [Weak]
    private var observers: [NSObjectProtocol] = []
    /// What the watch saw on a screen, once per window, in the order it saw them.
    private var shown: [String] = []
    private var shownWindows = Set<ObjectIdentifier>()

    /// Starts watching: the windows alive now are the baseline, and from now on every window move, screen change or
    /// occlusion change is checked for a test window showing on a screen.
    init() {
        baseline = NSApp.windows.map { Weak(window: $0) }
        let names = [
            NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didResizeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.checkShown(window) }
            }
        }
    }

    /// Checks every test window now for showing on a screen; the runner calls it once the test ends, before it
    /// closes the test's windows.
    func checkShownWindows() {
        for window in testWindows() { checkShown(window) }
    }

    /// Stops watching and returns what failed, or nil: each test window seen on a screen, and, when `leakTimeout` is
    /// given, each test window still alive after waiting that long for AppKit and the engine to release it.
    func finish(leakTimeout: TimeInterval?) async -> String? {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        var problems: [String] = []
        if !shown.isEmpty { problems.append("windows shown on a screen: " + shown.joined(separator: ", ")) }
        if let leakTimeout, let leaked = await leaks(timeout: leakTimeout) { problems.append(leaked) }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    // MARK: Showing on a screen

    private func checkShown(_ window: NSWindow) {
        guard window.isVisible, !shownWindows.contains(ObjectIdentifier(window)), isTestWindow(window) else { return }
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        guard onScreen || window.occlusionState.contains(.visible) else { return }
        shownWindows.insert(ObjectIdentifier(window))
        shown.append("\(Self.describe(window)) at \(window.frame)")
    }

    // MARK: Left alive

    /// Waits up to `timeout` for every test window to be released, checking each run loop turn. Returns nil when
    /// none is left, or a description of each one still alive.
    private func leaks(timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        // Held weakly: listing NSApp.windows on every turn would hand each window to an autorelease pool again.
        let candidates = testWindows().map { Weak(window: $0) }
        while true {
            let leaked = candidates.compactMap(\.window)
            if leaked.isEmpty { return nil }
            if Date() >= deadline {
                let list = leaked.map(Self.describe).joined(separator: ", ")
                return "windows still alive \(Int(timeout)) s after the test's teardown: \(list)"
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Which windows count

    /// The windows alive now that are the test's: not in the baseline and not of a persistent class.
    private func testWindows() -> [NSWindow] {
        NSApp.windows.filter(isTestWindow)
    }

    private func isTestWindow(_ window: NSWindow) -> Bool {
        Self.persistentClasses[NSStringFromClass(type(of: window))] == nil
            && !baseline.contains { $0.window === window }
    }

    private static func describe(_ window: NSWindow) -> String {
        var traits: [String] = []
        if window.isSheet { traits.append("sheet") }
        if window is NSPanel { traits.append("panel") }
        traits.append(window.isVisible ? "visible" : "hidden")
        return "\(NSStringFromClass(type(of: window))) \"\(window.title)\" (\(traits.joined(separator: ", ")))"
    }
}
