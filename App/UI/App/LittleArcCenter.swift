import AppKit
import BowCore

/// Little Arc for the whole app: the "links from other apps open in Little Arc" setting and the open Little Arc
/// windows (`LittleArcPanel`), one per link. The app delegate asks `LittleArc.opening` where each link from another
/// app goes and, for Little Arc, opens it here.
@MainActor
final class LittleArcCenter: AppFeature {
    /// The setting, in `AppSettings.defaults`. Unset means `LittleArc.opensExternalLinksByDefault` (on, as in Arc).
    static let opensExternalLinksKey = "littleArc.opensExternalLinks"

    #if BOW_E2E
        /// The screen area e2e runs open Little Arc in, off every screen, instead of the screen under the pointer.
        static var e2eVisibleFrame: NSRect?  // E2E seam
    #endif

    /// The open Little Arc windows, oldest first.
    private(set) var panels: [LittleArcPanel] = []

    init(dataDirectory: URL) {}

    /// The setting as the person left it, nil when they never set it.
    static var opensExternalLinks: Bool? {
        AppSettings.defaults.object(forKey: opensExternalLinksKey) as? Bool
    }

    /// Opens `url` in a new Little Arc window, its page in the profile of the Space `controller` shows (as a link
    /// opens in a browser window without Little Arc). `browserWindow` names the window a move goes to, at the moment
    /// of the move. With `takesFocus` the window comes forward and takes the keyboard; without (e2e) it is ordered in
    /// off screen. Returns the panel, or nil when the Space's profile is missing.
    @discardableResult
    func open(
        _ url: URL,
        from controller: BrowserWindowController,
        takesFocus: Bool,
        browserWindow: @escaping () -> BrowserWindowController?
    ) -> LittleArcPanel? {
        guard let profile = controller.activeProfile else { return nil }
        let tab = profile.createTab(url: url)
        let panel = LittleArcPanel(
            tab: tab, url: url, frame: Self.frame(), takesFocus: takesFocus, browserWindow: browserWindow
        ) { [weak self] closed in
            self?.panels.removeAll { $0 === closed }
        }
        panels.append(panel)
        panel.show()
        return panel
    }

    /// Closes every Little Arc window and its page at once, whatever the pages answer.
    func closeAll() {
        for panel in panels { panel.close(force: true) }
    }

    /// Where a new Little Arc window goes: centered on the screen under the pointer (else the key window's, else the
    /// main screen), inside its menu bar and Dock.
    private static func frame() -> NSRect {
        #if BOW_E2E
            if let frame = e2eVisibleFrame { return LittleArc.frame(in: frame) }  // E2E seam
        #endif
        let screens = NSScreen.screens
        let fallback = (NSApp.keyWindow?.screen ?? NSScreen.main).flatMap { screen in
            screens.firstIndex { $0 === screen }
        }
        guard
            let index = LittleArc.screenIndex(
                pointer: NSEvent.mouseLocation, screens: screens.map(\.frame), fallback: fallback)
        else { return NSRect(origin: .zero, size: LittleArc.defaultSize) }
        return LittleArc.frame(in: screens[index].visibleFrame)
    }
}
