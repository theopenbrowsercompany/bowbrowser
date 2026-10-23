import AppKit
import BowCore

/// The Favorites area at the top of the sidebar: the Favorites of the profile the Space on screen uses. For now each
/// Favorite is a plain row; the icon grid replaces this section.
struct FavoritesSection: SidebarSection {
    var zone: SidebarZone? { .favorites }

    func containerID(in graph: SidebarGraph, space: SidebarSpace) -> SidebarItemID? {
        graph.favoritesContainerID(for: space.profileID)
    }
}
