import AppKit
import BowCore

// The AppKit seam: the BowCore protocols have no views, so showing a tab goes through these, in App/UI only.
extension BowWebView {
    /// Shows `tab`, detaching the tab shown before. `tab` must come from `CEFEngine`; a closed tab is not shown.
    func show(_ tab: any EngineTab) {
        guard let tab = tab as? CEFTab else {
            assertionFailure("tab \(tab.tabID) did not come from CEFEngine")
            return
        }
        attach(tab.tab)
    }

    /// True while `tab` is the one this view shows.
    func isShowing(_ tab: any EngineTab) -> Bool {
        guard let attachedTab, let tab = tab as? CEFTab else { return false }
        return attachedTab === tab.tab
    }

    /// Gives the shown tab's page keyboard focus.
    func focusShownTab() { focusAttachedTab() }

    /// True while the view shows a tab's page.
    var showsTab: Bool { attachedTab != nil }
}

/// Site icons, the other AppKit seam: BowCore carries a tab's icon address, and the image is loaded here.
@MainActor
enum EngineFavicons {
    /// Loads the icon at `url` for `tab` through the tab's own profile, at most `maxPixelSize` pixels on a side,
    /// and calls `completion` on a later main thread task with the image, or nil when it could not be loaded.
    static func load(
        for tab: any EngineTab,
        from url: URL,
        maxPixelSize: Int,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        guard let tab = tab as? CEFTab else {
            assertionFailure("tab \(tab.tabID) did not come from CEFEngine")
            return
        }
        tab.tab.loadFavicon(at: url, maxPixelSize: UInt(maxPixelSize)) { image in
            MainActor.assumeIsolated { completion(image) }
        }
    }
}
