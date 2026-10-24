import AppKit
import BowCore
import WebKit

/// Who a web view asks before a key reaches its page: its tab (WebKitTab+Keys.swift). True claims the key, so the page
/// never sees it.
@MainActor
protocol KeyBeforePageHandler: AnyObject {
    func handleKeyBeforePage(_ event: NSEvent, kind: KeyBeforePageKind, in webView: WebKitWebView) -> Bool
}

/// Which part of a key press a web view asks about.
enum KeyBeforePageKind {
    case keyDown
    case keyUp
}

/// Who a web view hands the context menu WebKit is about to open: its tab (WebKitTab+ContextMenu.swift), which
/// rebuilds the menu in place from its delegate's answer.
@MainActor
protocol ContextMenuHandler: AnyObject {
    func willOpenContextMenu(_ menu: NSMenu, with event: NSEvent, in webView: WebKitWebView)
}

/// The web view of every Bow tab.
final class WebKitWebView: WKWebView {
    /// Key codes whose key down was claimed: their key up is the same press, so it never reaches a page either. Kept
    /// for every web view at once, because a claimed shortcut often moves focus (Control Tab shows another tab), and
    /// the key up then reaches another tab's page.
    private static var claimedKeyCodes: Set<UInt16> = []
    /// The key down asked about last and the answer, so a key down that reaches both `performKeyEquivalent` and
    /// `keyDown` (or that WebKit sends again after the page left it unhandled) is asked about once.
    private var lastAsked: (event: NSEvent, claimed: Bool)?
    /// The page's open alert, confirm and prompt panels, each answered exactly once (WebKitTab+Dialogs.swift).
    var openDialogs: [ObjectIdentifier: PageDialogReply] = [:]
    /// What the context menu script reported from each frame since the mouse down that may open a menu, oldest
    /// first (WebKitTab+ContextMenu.swift).
    var contextMenuReports: [ContextMenuPageReport] = []
    /// Where the mouse down that may open a menu was, in window coordinates: the event WebKit hands `willOpenMenu`
    /// carries no location of the click.
    private(set) var contextMenuClick: NSPoint?
    /// True from the tab answering WebKit's private ask for a menu until that menu is about to open.
    var contextMenuHandled = false
    /// How many menus WebKit asked the tab for through its private callback, for the test that WebKit calls it.
    var contextMenuCallbacks = 0
    /// Test only: called with each context menu once the tab rebuilt it, before it opens; false keeps it from
    /// opening where WebKit asked the tab for it (WebKit's private callback).
    var onContextMenu: ((NSMenu) -> Bool)?

    /// A click into an inactive window reaches the page, not only the window: the W1 spike found WebKit otherwise
    /// drops the first click into an inactive app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The tab lets the page go by dropping itself as the UI delegate: every panel still open is cancelled then, so
    /// the page's completion handlers are all called before the web view goes away.
    override var uiDelegate: (any WKUIDelegate)? {
        didSet {
            if uiDelegate == nil { cancelOpenDialogs() }
        }
    }

    // MARK: Context menu

    /// A right click, or a Control click, may open a menu: the script's reports of earlier clicks are dropped first,
    /// so only this click's reports reach the menu.
    override func rightMouseDown(with event: NSEvent) {
        startContextMenuClick(event)
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { startContextMenuClick(event) }
        super.mouseDown(with: event)
    }

    private func startContextMenuClick(_ event: NSEvent) {
        contextMenuReports = []
        contextMenuClick = event.locationInWindow
    }

    /// The click's reports and place are used up once its menu is built.
    func endContextMenuClick() {
        contextMenuReports = []
        contextMenuClick = nil
    }

    /// The menu about to open. When WebKit asked the tab for it first (its private callback, see
    /// WebKitTab+ContextMenu.swift), it is already Bow's; otherwise the tab rebuilds it here, the public fallback.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        if contextMenuHandled {
            contextMenuHandled = false
            return
        }
        (uiDelegate as? ContextMenuHandler)?.willOpenContextMenu(menu, with: event, in: self)
        _ = onContextMenu?(menu)
        endContextMenuClick()
    }

    // MARK: Keys before the page

    /// A key with Command (or another key equivalent) comes here before `keyDown`, also when the page does not have
    /// focus; only the page with keyboard focus asks its tab.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, hasKeyFocus, askBeforePage(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if askBeforePage(event) { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if Self.claimedKeyCodes.remove(event.keyCode) != nil { return }
        if let handler = uiDelegate as? KeyBeforePageHandler,
            handler.handleKeyBeforePage(event, kind: .keyUp, in: self)
        {
            return
        }
        super.keyUp(with: event)
    }

    /// Whether the tab claims key down `event`, asked once per event.
    private func askBeforePage(_ event: NSEvent) -> Bool {
        if let lastAsked, lastAsked.event === event || Self.isSamePress(lastAsked.event, event) {
            return lastAsked.claimed
        }
        let claimed =
            (uiDelegate as? KeyBeforePageHandler)?.handleKeyBeforePage(event, kind: .keyDown, in: self) ?? false
        lastAsked = (event, claimed)
        if claimed {
            Self.claimedKeyCodes.insert(event.keyCode)
        } else {
            Self.claimedKeyCodes.remove(event.keyCode)
        }
        return claimed
    }

    /// Two events for one key down (AppKit and WebKit may hand the same press on as a copy).
    private static func isSamePress(_ a: NSEvent, _ b: NSEvent) -> Bool {
        a.type == b.type && a.timestamp == b.timestamp && a.keyCode == b.keyCode && a.windowNumber == b.windowNumber
            && a.modifierFlags == b.modifierFlags
    }

    /// True while the web view, or a view inside it, is its window's first responder.
    private var hasKeyFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    // MARK: Dialogs

    private func cancelOpenDialogs() {
        let open = openDialogs.values
        openDialogs = [:]
        for reply in open { reply.answer(.cancelled) }
    }
}
