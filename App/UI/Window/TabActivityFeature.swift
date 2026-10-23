import AppKit
import BowCore

/// Reports a window's tab activity to the app's `TabActivityLog`: a tab counts as active when it becomes the one the
/// window shows, and again when its window becomes the key window.
@MainActor
final class TabActivityFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?
    private let log: TabActivityLog
    private var shownItem: SidebarItemID?

    init(window: BrowserWindowController) {
        self.window = window
        log = window.appFeatures.require(TabActivityLog.self)
        super.init()
        log.pruneOnce(keeping: Set(window.store.graph.items.keys))
        if let nsWindow = window.window {
            _ = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nsWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let item = self?.shownItem { self?.log.record(item) }
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        let item = tab.flatMap { tab in
            window?.modelID(of: tab).flatMap { window?.sidebarItemID(for: $0) }
        }
        // The tab list changing (a tab opening or closing) reports the same tab again: that is not a selection.
        guard item != shownItem else { return }
        shownItem = item
        if let item { log.record(item) }
    }
}
