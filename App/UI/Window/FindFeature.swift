import AppKit
import BowCore

/// Find in page: the find bar floating over the page's top right corner (Edit > Find, Cmd+F), Find Next and Find
/// Previous. The bar searches the tab it was opened over and closes when another tab is shown or that tab closes.
@MainActor
final class FindFeature: NSResponder, BrowserWindowFeature {
    private unowned let window: BrowserWindowController
    /// The find in page bar, hidden until Cmd+F.
    let findBar = FindBar()
    /// The tab the find bar searches in while it is shown.
    private var findTab: (any EngineTab)?

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        let pageArea = window.pageArea
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        pageArea.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: pageArea.topAnchor, constant: 12),
            findBar.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor, constant: -16),
        ])
        findBar.onTextChange = { [weak self] _ in self?.runFind(forward: true) }
        findBar.onStep = { [weak self] forward in self?.runFind(forward: forward) }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Edit > Find, handled by the key window's find feature.
    static func addMenuItems(to menus: MainMenu.Menus) {
        let menu = NSMenu(title: "Find")
        menu.addItem(withTitle: "Find…", action: #selector(showFindBar(_:)), keyEquivalent: "f")
        menu.addItem(withTitle: "Find Next", action: #selector(findNext(_:)), keyEquivalent: "g")
        menu.addItem(withTitle: "Find Previous", action: #selector(findPrevious(_:)), keyEquivalent: "G")
        menus.edit.addItem(.separator())
        menus.edit.addItem(MainMenu.item(for: menu))
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        // Called after the window shows the tab, so the keyboard the find bar gives back goes to the page now shown.
        if let tab, let findTab, findTab !== tab { closeFindBar() }
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        if case .findResult(let result) = event, tab === findTab { findBar.show(result) }
    }

    func tabDidClose(_ tab: any EngineTab) {
        if tab === findTab { closeFindBar() }
    }

    /// Edit > Find (Cmd+F): shows the find bar over the shown tab with the keyboard in its field, searching again
    /// for the text it kept from last time.
    @objc func showFindBar(_ sender: Any?) {
        guard let tab = window.selectedTab else { return }
        let wasShown = !findBar.isHidden
        findTab = tab
        findBar.isHidden = false
        findBar.focus()
        if !wasShown { runFind(forward: true) }
    }

    /// Edit > Find Next (Cmd+G), also Enter in the find bar.
    @objc func findNext(_ sender: Any?) {
        stepFind(forward: true)
    }

    /// Edit > Find Previous (Shift+Cmd+G), also Shift+Enter in the find bar.
    @objc func findPrevious(_ sender: Any?) {
        stepFind(forward: false)
    }

    private func stepFind(forward: Bool) {
        // A closed bar opens and searches again, which already makes a match active; stepping too would skip one.
        if findBar.isHidden {
            showFindBar(nil)
        } else {
            runFind(forward: forward)
        }
    }

    /// Searches the find bar's tab for the bar's text: a new search when the text changed, otherwise a step to the
    /// next or previous match. Empty text stops the search and clears the count.
    private func runFind(forward: Bool) {
        guard let findTab else { return }
        let text = findBar.text
        if text.isEmpty {
            findTab.stopFind()
            findBar.show(nil)
        } else {
            findTab.find(text, forward: forward, matchCase: false)
        }
    }

    /// Hides the find bar and stops its search, clearing the page's highlights. The bar keeps its text for next
    /// time, and the keyboard goes back to the page.
    func closeFindBar() {
        guard let tab = findTab else { return }
        findTab = nil
        tab.stopFind()
        findBar.show(nil)
        let hadKeyboard = findBar.field.currentEditor() != nil
        findBar.isHidden = true
        if hadKeyboard { window.webView.focusAttachedTab() }
    }
}
