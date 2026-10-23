import AppKit
import BowCore

/// The sidebar along the window's leading edge, listing its tabs with their site icons (`TabSidebarView`): a click
/// shows a tab, its close button closes it, a drag reorders the list, and the New Tab button opens a tab.
@MainActor
final class SidebarFeature: NSResponder, BrowserWindowFeature, TabSidebarDelegate {
    /// The size, in pixels, site icons are loaded at (16 points on a Retina screen).
    private static let faviconPixelSize = 32

    private unowned let window: BrowserWindowController
    let sidebar = TabSidebarView(frame: .zero)
    /// The site icon each tab shows and the address it came from.
    private var favicons: [BrowserTabID: (url: URL, image: NSImage)] = [:]
    /// The icon address each tab's page reported last, nil while it reports none.
    private var faviconReported: [BrowserTabID: URL] = [:]

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        window.attachLeadingView(sidebar, width: TabSidebarView.width)
        sidebar.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        sidebar.show(window.tabList)
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        guard case .stateChanged(let state) = event, let id = window.modelID(of: tab) else { return }
        updateFavicon(of: id, tab: tab, url: state.faviconURL)
        sidebar.show(window.tabList)
    }

    func tabDidClose(_ tab: any EngineTab) {
        guard let id = window.modelID(of: tab) else { return }
        favicons[id] = nil
        faviconReported[id] = nil
    }

    // MARK: TabSidebarDelegate

    func sidebar(_ sidebar: TabSidebarView, select id: BrowserTabID) {
        window.select(id)
    }

    func sidebar(_ sidebar: TabSidebarView, close id: BrowserTabID) {
        guard let tab = window.engineTab(for: id) else { return }
        Task { await window.closeTab(tab) }
    }

    func sidebar(_ sidebar: TabSidebarView, move id: BrowserTabID, to index: Int) {
        window.reorderTab(id, to: index)
        sidebar.show(window.tabList)
    }

    func sidebarNewTab(_ sidebar: TabSidebarView) {
        window.newTab(sidebar)
    }

    func sidebar(_ sidebar: TabSidebarView, faviconFor id: BrowserTabID) -> NSImage? {
        favicons[id]?.image
    }

    /// Loads the site icon at `url` for tab `id` each time the page reports a new icon address. The icon shown stays
    /// while a navigation has no address yet, so rows do not flicker; it goes once a new address fails to load.
    /// An address that failed is tried again when the page reports it anew.
    private func updateFavicon(of id: BrowserTabID, tab: any EngineTab, url: URL?) {
        guard faviconReported[id] != url else { return }
        faviconReported[id] = url
        guard let url, favicons[id]?.url != url else { return }
        EngineFavicons.load(for: tab, from: url, maxPixelSize: Self.faviconPixelSize) { [weak self] image in
            guard let self, self.faviconReported[id] == url else { return }
            self.favicons[id] = image.map { (url, $0) }
            self.sidebar.reloadTab(id)
        }
    }
}
