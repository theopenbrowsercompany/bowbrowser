import AppKit
import BowCore

/// Back, forward, reload and stop for the window's selected tab: the toolbar buttons, History > Back and Forward,
/// and View > Stop and Reload Page. The buttons and menu items follow the active tab's `NavigationControls`.
@MainActor
final class NavigationFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController
    /// The back, forward and reload or stop buttons in the window's toolbar.
    let toolbar = NavigationToolbar()
    /// What the navigation controls offer for the active tab; the toolbar and the menu items follow it.
    private(set) var controls = NavigationControls.disabled

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        if let nsWindow = window.window { toolbar.install(in: nsWindow, target: self) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Back and forward act on the key window's selected tab, which enables them; so do reload and stop.
    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.view.addItem(withTitle: "Stop", action: #selector(stopLoading(_:)), keyEquivalent: ".")
        menus.view.addItem(withTitle: "Reload Page", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        menus.history.addItem(withTitle: "Back", action: #selector(goBack(_:)), keyEquivalent: "[")
        menus.history.addItem(withTitle: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]")
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        updateControls()
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        if case .stateChanged = event, let id = window.modelID(of: tab), id == window.tabList.activeID {
            updateControls()
        }
    }

    /// Goes back in the selected tab's history (toolbar button, History > Back, Cmd+[).
    @objc func goBack(_ sender: Any?) {
        window.selectedTab?.goBack()
    }

    /// Goes forward in the selected tab's history (toolbar button, History > Forward, Cmd+]).
    @objc func goForward(_ sender: Any?) {
        window.selectedTab?.goForward()
    }

    /// Reloads the selected tab (toolbar button while idle, View > Reload Page, Cmd+R), also while it loads.
    @objc func reloadPage(_ sender: Any?) {
        window.selectedTab?.reload()
    }

    /// Stops the selected tab's load (toolbar button while loading, View > Stop, Cmd+.).
    @objc func stopLoading(_ sender: Any?) {
        window.selectedTab?.stop()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): controls.canGoBack
        case #selector(goForward(_:)): controls.canGoForward
        case #selector(reloadPage(_:)): controls.canReload
        case #selector(stopLoading(_:)): controls.canStop
        default: true
        }
    }

    /// Reads the controls from the tab list's active tab and shows them in the toolbar.
    private func updateControls() {
        let activeTab = window.tabList.activeTab.flatMap { window.engineTab(for: $0.id)?.isClosed == false ? $0 : nil }
        controls = NavigationControls(activeTab: activeTab)
        toolbar.show(controls)
    }
}
