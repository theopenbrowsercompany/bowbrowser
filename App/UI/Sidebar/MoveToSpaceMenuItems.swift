import AppKit
import BowCore

/// "Move to Space" for a tab row: a submenu of every other Space, as Arc's tab menu moves a tab to another Space. The
/// tab goes to the top of the same section (pinned or today) there. Between Spaces of one profile it keeps its live
/// page; to a Space of another profile the app service `ProfileMoves` asks first and loads the page again there.
enum MoveToSpaceMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.tab] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        let targets = context.graph.spaceMoveTargets(for: item)
        guard !targets.isEmpty,
            let owner = (context as? SidebarFeature)?.sidebar.window?.windowController as? BrowserWindowController
        else { return [] }
        let moves = owner.appFeatures.require(ProfileMoves.self)
        let menu = NSMenu(title: "Move to Space")
        for space in targets {
            menu.addItem(
                SidebarMenuItem(title: space.title) { [weak owner] in
                    guard let owner else { return }
                    moves.moveTab(item, toSpace: space.id, in: owner)
                })
        }
        let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        move.submenu = menu
        return [move]
    }
}
