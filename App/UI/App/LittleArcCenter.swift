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

    /// Opens `url` in a new Little Arc window, its page in `profile`: the profile of the Space the browser window
    /// shows (as a link opens in a browser window without Little Arc), or with no browser window the Space shown last.
    /// `permissions` answers the page's permission requests (nil dismisses them). `browserWindow` names the window a
    /// move goes to, at the moment of the move, and `openWindow` opens one for Open in Bow when none is open. With
    /// `takesFocus` the window comes forward and takes the keyboard; without (e2e) it is ordered in off screen.
    /// `closed` runs once the window has gone, closed or moved, after it has left `panels`.
    @discardableResult
    func open(
        _ url: URL,
        in profile: any EngineProfile,
        permissions: PermissionPrompts.ProfilePermissions?,
        takesFocus: Bool,
        browserWindow: @escaping () -> BrowserWindowController?,
        openWindow: @escaping (SidebarProfileID) -> BrowserWindowController?,
        closed: @escaping () -> Void
    ) -> LittleArcPanel {
        let tab = profile.createTab(url: url)
        let panel = LittleArcPanel(
            tab: tab, url: url, frame: Self.frame(), takesFocus: takesFocus, permissions: permissions,
            browserWindow: browserWindow, openWindow: openWindow
        ) { [weak self] panel in
            self?.panels.removeAll { $0 === panel }
            closed()
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
