import AppKit
import BowCore

/// "Remove from Favorites" for a Favorite: takes it out of the grid and keeps it as a tab at the top of today in the
/// Space on screen, as Arc's un-favorite does (a Favorite leaves the grid by moving to a section, never by being lost).
enum FavoritesMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.favorite] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        [
            SidebarMenuItem(title: "Remove from Favorites") { [weak context] in
                context?.changeSidebar { try $0.removeFavorite(item, to: .unpinned, at: 0) }
            }
        ]
    }
}
