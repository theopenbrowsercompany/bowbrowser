import AppKit
import BowCore

/// The page context menu's window commands. The window shows Bow's own menu (`ContextMenuPolicy`) when no feature
/// answers; this feature runs the items only a window can: Open Link in New Tab opens the link as a new today tab in
/// the background, right after the tab, as a Cmd-click does (`PopupPolicy.plainLinkDecision`); Copy Image puts the image
/// itself on the pasteboard, which the engine has no command for.
@MainActor
final class ContextMenuFeature: NSResponder, BrowserWindowFeature {
    /// The largest side, in pixels, of an image Copy Image fetches whole; the engine scales a larger one down.
    static let maxImagePixels = 16384

    private weak var window: BrowserWindowController?
    /// Where Copy Image puts the image: the general pasteboard, or a private one a test gives.
    var pasteboard: NSPasteboard = .general

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
        switch command {
        case .openLinkInNewTab:
            guard let window, let url = request.linkURL else { return false }
            window.openTab(url: url, select: false)
            return true
        case .copyImage:
            guard let url = request.imageURL else { return false }
            copyImage(at: url, from: tab)
            return true
        default:
            return false
        }
    }

    /// Fetches the image in the tab's own request context (its profile's cookies and cache) and puts the image itself
    /// on the pasteboard; an image that cannot be fetched leaves the pasteboard alone.
    private func copyImage(at url: URL, from tab: any EngineTab) {
        EngineFavicons.load(for: tab, from: url, maxPixelSize: Self.maxImagePixels) { [weak self] image in
            guard let self, let image else { return }
            self.pasteboard.clearContents()
            self.pasteboard.writeObjects([image])
        }
    }
}
