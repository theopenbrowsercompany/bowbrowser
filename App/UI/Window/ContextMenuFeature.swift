import AppKit
import BowCore

/// The page context menu's window commands. The window shows Bow's own menu (`ContextMenuPolicy`) when no feature
/// answers; this feature runs the items only a window can: Open Link in New Tab opens the link as a new today tab in
/// the background, right after the tab, as a Cmd-click does (`PopupPolicy.plainLinkDecision`).
@MainActor
final class ContextMenuFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func runContextMenuCommand(_ command: ContextMenuCommand, request: ContextMenuRequest, in tab: any EngineTab)
        -> Bool
    {
        guard command == .openLinkInNewTab, let window, let url = request.linkURL else { return false }
        window.openTab(url: url, select: false)
        return true
    }
}
