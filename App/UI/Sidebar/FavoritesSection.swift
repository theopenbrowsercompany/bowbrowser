import AppKit
import BowCore

/// The Favorites area at the top of the sidebar: the Favorites of the profile the Space on screen uses, drawn as an
/// icon grid (`FavoritesGridView`) in the section's header row, which grows a row at a time with its icons. The
/// section lists no outline rows of its own: the grid draws every Favorite and handles their clicks, drags and menus.
struct FavoritesSection: SidebarSection {
    var zone: SidebarZone? { .favorites }

    func containerID(in graph: SidebarGraph, space: SidebarSpace) -> SidebarItemID? { nil }

    func headerHeight(for content: SidebarContent) -> CGFloat {
        FavoritesGridLayout.height(for: content.graph.activeFavoriteIDs.count)
    }

    func makeHeaderView() -> NSView? { FavoritesGridView() }

    func updateHeaderView(_ view: NSView, content: SidebarContent, context: (any SidebarActionContext)?) {
        (view as? FavoritesGridView)?.update(content: content, context: context)
    }
}
