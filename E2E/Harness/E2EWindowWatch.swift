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
    /// change or occlusion change is checked for a test window showing on a screen.
    init() {
        baseline = NSApp.windows.map { Weak(window: $0) }
        let names = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.check(window) }
            }
        }
    }

    /// Checks every test window once more, stops watching, and returns each test window seen on a screen, or nil.
    /// The runner calls it once the test ends, before it closes the test's windows.
    func finish() -> String? {
        for window in NSApp.windows { check(window) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        return shown.isEmpty ? nil : "windows shown on a screen: " + shown.joined(separator: ", ")
    }

    /// Records `window` when it is a test window that is visible and either overlaps a screen or is reported
    /// visible by the window server.
    private func check(_ window: NSWindow) {
        guard window.isVisible, !shownWindows.contains(ObjectIdentifier(window)),
            Self.exemptClasses[NSStringFromClass(type(of: window))] == nil,
            !baseline.contains(where: { $0.window === window })
        else { return }
        let overlapsScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        guard overlapsScreen || window.occlusionState.contains(.visible) else { return }
        shownWindows.insert(ObjectIdentifier(window))
        var traits: [String] = []
        if window.isSheet { traits.append("sheet") }
        if window is NSPanel { traits.append("panel") }
        let kind = traits.isEmpty ? "" : " (\(traits.joined(separator: ", ")))"
        shown.append("\(NSStringFromClass(type(of: window))) \"\(window.title)\"\(kind) at \(window.frame)")
    }
}
