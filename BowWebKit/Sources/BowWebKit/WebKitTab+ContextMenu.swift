import AppKit
import BowCore
import WebKit

// The context menu (`EngineTabDelegate.tab(_:decideContextMenu:)` and `tab(_:runContextMenuCommand:request:)`).
// WebKit gives no hit test of its own: a script in Bow's own content world reports the target from every frame on
// each `contextmenu` event (Scripts/ContextMenuTarget.js), and WebKit's proposed menu says which kinds of target the
// click hit. `ContextMenuTargets` merges the two into the request, the delegate decides, and the tab rebuilds
// WebKit's menu in place from the answer before it opens. WebKit hands the menu over through its private callback
// (`WebKitSPI.Callback.getContextMenu`), where the tab can also hand back none so nothing opens; where WebKit drops
// it, `willOpenMenu(_:with:)` (WebKitWebView.swift) is the public fallback, which cannot stop a menu opening, so a
// `.none` answer there opens an empty box.
// A page that cancels its `contextmenu` event gets no menu and no question, as in Safari and the CEF engine.

extension WebKitTab: ContextMenuHandler {
    /// The content world the target script runs in, apart from the page's own scripts, which can neither see its
    /// message handler nor post to it.
    static let contextMenuWorld = WKContentWorld.world(name: "BowContextMenu")
    static let contextMenuHandlerName = "bowContextMenu"

    /// The target script, a package resource read once.
    static let contextMenuScript: String? = {
        guard
            let url = Bundle.module.url(forResource: "ContextMenuTarget", withExtension: "js", subdirectory: "Scripts")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// Where Copy Link Address and Copy Image Address put the address; tests give their own pasteboard.
    static var contextMenuPasteboard = NSPasteboard.general

    /// Adds the target script to `webView`, which the tab is installing.
    func observeContextMenu(of webView: WKWebView) {
        onGetContextMenu = { [weak self] proposed, webView, done in
            guard let self else { return done(proposed) }
            self.provideContextMenu(proposed, in: webView, done: done)
        }
        guard let source = Self.contextMenuScript else {
            assertionFailure("Scripts/ContextMenuTarget.js is missing from the BowWebKit bundle")
            return
        }
        // A content controller can be shared (WebKit gives a popup its opener's), and adding a handler name twice
        // raises, so a controller gets the handler and the script once; the relay finds each message's web view.
        let content = webView.configuration.userContentController
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        content.add(ContextMenuScriptRelay(), contentWorld: Self.contextMenuWorld, name: Self.contextMenuHandlerName)
        content.addUserScript(
            WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.contextMenuWorld))
    }

    /// WebKit's private ask for the menu, before it opens (`WebKitSPI.Callback.getContextMenu`): the tab rebuilds the
    /// proposed menu and hands it back, or nil to show nothing, so no menu ever opens empty.
    func provideContextMenu(_ proposed: NSMenu, in webView: WKWebView, done: (NSMenu?) -> Void) {
        guard let webView = webView as? WebKitWebView, webView === self.webView, !isClosed else {
            return done(proposed)
        }
        webView.contextMenuCallbacks += 1
        let click = webView.contextMenuClick ?? webView.window?.mouseLocationOutsideOfEventStream ?? .zero
        let shows = rebuild(proposed, click: click, in: webView)
        if !shows { proposed.removeAllItems() }
        let allowed = webView.onContextMenu?(proposed) ?? true
        let opens = shows && allowed
        webView.endContextMenuClick()
        // The menu handed back reaches `willOpenMenu` next, which leaves it as it is.
        webView.contextMenuHandled = opens
        done(opens ? proposed : nil)
    }

    func willOpenContextMenu(_ menu: NSMenu, with event: NSEvent, in webView: WebKitWebView) {
        guard webView === self.webView, !isClosed else { return }
        // The click's mouse down, else the pointer now (a menu opened by no click).
        let click =
            webView.contextMenuClick ?? webView.window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
        if !rebuild(menu, click: click, in: webView) { Self.empty(menu) }
    }

    /// Rebuilds WebKit's `menu` from the delegate's answer to the click at `click` (window coordinates); false when
    /// the answer is to show nothing.
    private func rebuild(_ menu: NSMenu, click: NSPoint, in webView: WebKitWebView) -> Bool {
        guard let delegate else { return true }
        let request = ContextMenuTargets.request(
            hints: ContextMenuHints(menu),
            reports: webView.contextMenuReports,
            profileID: profileID,
            position: PagePoint(window: click, in: webView),
            pageURL: state.url,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward
        )
        let decision = delegate.tab(self, decideContextMenu: request)
        if case .show(let items) = decision {
            menu.removeAllItems()
            menu.autoenablesItems = false
            for item in items {
                menu.addItem(ContextMenuCommandItem.menuItem(item, tab: self, request: request))
            }
        }
        return decision != .none
    }

    /// Empties `menu`, for the public fallback's answer to show nothing. AppKit still opens an empty menu, as a
    /// small blank box at the pointer (only WebKit's private callback can stop the menu opening), so at least none of
    /// AppKit's own items (Services, Writing Tools) go in it.
    static func empty(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.allowsContextMenuPlugIns = false
        menu.automaticallyInsertsWritingToolsItems = false
    }

    /// Runs `command`, chosen from the menu built for `request` while the page was at `address`: in the app first,
    /// else here. Dropped when the page moved to another address or the tab closed while the menu was open.
    func runContextMenuCommand(_ command: ContextMenuCommand, request: ContextMenuRequest, address: URL?) {
        guard !isClosed, let webView, state.url == address else { return }
        if delegate?.tab(self, runContextMenuCommand: command, request: request) == true { return }
        // Not exhaustive on purpose: a command added to BowCore does nothing here until it is wired.
        switch command {
        case .copyLinkAddress: Self.copyAddress(request.linkURL)
        case .copyImageAddress: Self.copyAddress(request.imageURL)
        case .back: goBack()
        case .forward: goForward()
        case .reload: reload()
        case .undo: webView.undoManager?.undo()
        case .redo: webView.undoManager?.redo()
        case .cut: webView.tryToPerform(#selector(NSText.cut(_:)), with: nil)
        case .copy: webView.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        case .paste: webView.tryToPerform(#selector(NSText.paste(_:)), with: nil)
        case .selectAll: webView.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        case .inspect: showInspector(inspectingAt: request.position)
        default: break  // Open Link in New Tab, Copy Image and custom items are the app's alone.
        }
    }

    private static func copyAddress(_ url: URL?) {
        guard let url else { return }
        contextMenuPasteboard.clearContents()
        contextMenuPasteboard.setString(url.absoluteString, forType: .string)
    }
}

/// The target of one item of a menu the tab rebuilt: it holds the command and the request it was built for, and the
/// tab weakly, so a menu kept after the tab closed keeps no tab alive. The menu item holds it strongly, as its
/// represented object, since a menu item holds its target weakly.
@MainActor
final class ContextMenuCommandItem: NSObject {
    let command: ContextMenuCommand
    let request: ContextMenuRequest
    let address: URL?
    weak var tab: WebKitTab?

    private init(command: ContextMenuCommand, request: ContextMenuRequest, tab: WebKitTab) {
        self.command = command
        self.request = request
        address = tab.state.url
        self.tab = tab
    }

    /// The native item for `item`: a separator, or an item whose choice runs its command through the tab.
    static func menuItem(_ item: ContextMenuItem, tab: WebKitTab, request: ContextMenuRequest) -> NSMenuItem {
        guard let command = item.command else { return .separator() }
        let target = ContextMenuCommandItem(command: command, request: request, tab: tab)
        let menuItem = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
        menuItem.target = target
        menuItem.representedObject = target
        menuItem.isEnabled = item.isEnabled
        return menuItem
    }

    @objc func choose(_ sender: Any?) {
        tab?.runContextMenuCommand(command, request: request, address: address)
    }
}

/// Hands the target script's messages to the web view that sent them, as reports of the click in the frame that
/// posted. It holds no web view or tab, so the content controller, which keeps its handlers strongly, keeps none
/// alive, and a controller shared by several web views reaches each one.
@MainActor
final class ContextMenuScriptRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? WebKitWebView,
            let report = ContextMenuPageReport(body: message.body, isMainFrame: message.frameInfo.isMainFrame)
        else { return }
        webView.contextMenuReports.append(report)
        // A click whose menu never opened (the page cancelled it) leaves its reports; keep only the latest few.
        if webView.contextMenuReports.count > 16 { webView.contextMenuReports.removeFirst() }
    }
}
