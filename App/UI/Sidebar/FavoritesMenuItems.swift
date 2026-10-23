import AppKit
import BowCore

/// "Remove from Favorites" for a Favorite: takes it out of the grid and keeps it as a tab at the top of today in the
/// Space on screen, as Arc's un-favorite does (a Favorite leaves the grid by moving to a section, never by being lost).
/// It keeps its open page, which becomes its saved page, so a relaunch brings it back where it was.
enum FavoritesMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.favorite] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        [
            SidebarMenuItem(title: "Remove from Favorites") { [weak context] in
                guard let context else { return }
                let page = context.livePage(of: item)
                // Two changes, as removing opens its own transaction: the page is recorded only once the tab has
                // left the grid, so a refused removal leaves the Favorite's saved address alone.
                guard context.changeSidebar({ try $0.removeFavorite(item, to: .unpinned, at: 0) }), let page else {
                    return
                }
                context.changeSidebar {
                    try $0.apply([.setSavedPage(item, url: page.url.absoluteString, title: page.title)])
                }
            }
        ]
    }
}
