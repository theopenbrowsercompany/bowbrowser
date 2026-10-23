import AppKit
import BowCore

/// What a sidebar item is, for choosing its context menu items.
enum SidebarItemKind: Hashable, Sendable {
    case tab
    case folder
    case split
    case favorite
    /// A section's header row, for the section listing items of that zone. The menu's item is the container the
    /// section lists (for "New Folder" in pinned, say).
    case section(SidebarZone)

    /// The kind of `id` in `graph`, or nil for a container or an unknown item. A section's kind comes from the row
    /// clicked, not the graph: see `SidebarMenus.menu(for:kind:context:)`.
    init?(of id: SidebarItemID, in graph: SidebarGraph) {
        switch graph[id]?.data {
        case .tab?: self = graph.isInFavorites(id) ? .favorite : .tab
        case .folder?: self = .folder
        case .split?: self = .split
        case .container?, nil: return nil
        }
    }
}

/// What sidebar actions (context menu items, drops, accessories, section headers, the swipe handler) may do to the
/// window: read its sidebar, select, close, load or open a tab, change the store, rename a folder in place and slide
/// the outline. The sidebar feature provides it.
@MainActor
protocol SidebarActionContext: AnyObject {
    /// The window's committed sidebar.
    var graph: SidebarGraph { get }
    /// Makes tab `item` active and shows it.
    func select(_ item: SidebarItemID)
    /// Closes tab `item` as its close button does.
    func close(_ item: SidebarItemID)
    /// Runs `body` on the store, then brings the window up to date. Returns whether the change went through.
    @discardableResult
    func changeSidebar(_ body: (SidebarStore) throws -> Void) -> Bool
    /// The page tab `item` shows right now, nil while it has not loaded.
    func livePage(of item: SidebarItemID) -> (url: URL, title: String)?
    /// Loads `url` in tab `item` of the Space on screen (as "Back to pinned URL" does): a loaded tab navigates, and a
    /// tab whose saved page has not loaded is shown and loaded there, the way the window loads saved pages. Returns
    /// whether a page was asked to load; false for a Favorite or an item that is not such a tab.
    @discardableResult
    func load(_ item: SidebarItemID, url: URL) -> Bool
    /// The site icon loaded for tab `item`, nil while there is none. Only tabs of the Space on screen load pages, so a
    /// Favorite has none until Favorites load in place.
    func favicon(for item: SidebarItemID) -> NSImage?
    /// Opens Favorite `item` (a click on it in the Favorites grid): its saved page loads in a new tab in today of the
    /// Space on screen, which is shown, as opening any address does. Returns whether a tab opened; false for an item
    /// that is not a tab in the Favorites the Space on screen shows.
    @discardableResult
    func open(favorite item: SidebarItemID) -> Bool
    /// Makes the name of folder or split `item` editable in its row (a "Rename" menu item, a new folder); the new
    /// name is saved as the item's title when the edit ends with Return or by leaving the field, and Escape keeps
    /// the old one. Returns false when the item has no row on screen (it is inside a closed folder, or not a folder
    /// or split).
    @discardableResult
    func beginRename(_ item: SidebarItemID) -> Bool
    /// Runs `change`, which changes what the sidebar shows (switching Spaces through `changeSidebar`), with the
    /// outline's old content sliding out towards `direction` as the new comes in: `SidebarView.slideOutline`.
    func slideOutline(_ direction: SidebarSlideDirection, change: () -> Void)
}

/// Context menu items for sidebar items of some kinds.
///
/// Extension point: a new set of items (Pin and Unpin, folder actions, Favorite actions, a section's "New Folder")
/// is one new file with a type conforming to this protocol plus one line in `SidebarMenus.all`
/// (`SidebarMenuList.swift`). The menu lists each provider's items in list order, with a separator between providers.
@MainActor
protocol SidebarMenuItems {
    /// The kinds of item this provider adds to.
    static var kinds: Set<SidebarItemKind> { get }
    /// The items for `item` (for a `.section` kind, the container the section lists); empty adds nothing.
    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem]
}

extension SidebarMenus {
    /// The context menu of `item`: each provider's items for its kind, separated by provider.
    static func menu(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        guard let kind = SidebarItemKind(of: item, in: context.graph) else { return [] }
        return menu(for: item, kind: kind, context: context)
    }

    /// The context menu of `item` as an item of `kind` (a section's container as `.section`).
    static func menu(for item: SidebarItemID, kind: SidebarItemKind, context: any SidebarActionContext) -> [NSMenuItem]
    {
        var result: [NSMenuItem] = []
        for provider in all where provider.kinds.contains(kind) {
            let items = provider.menuItems(for: item, context: context)
            guard !items.isEmpty else { continue }
            if !result.isEmpty { result.append(.separator()) }
            result += items
        }
        return result
    }
}

/// A menu item that runs a closure, so providers need no target object of their own.
@MainActor
final class SidebarMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run(_ sender: Any?) {
        handler()
    }
}

/// "Close Tab" for a tab row, as its close button does (a pinned tab only unloads and stays).
enum CloseTabMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.tab] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        [SidebarMenuItem(title: "Close Tab") { [weak context] in context?.close(item) }]
    }
}
