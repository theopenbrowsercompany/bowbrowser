import AppKit
import BowCore

/// "Move to Space" for a tab row: a submenu of every other Space, as Arc's tab menu moves a tab to another Space. The
/// tab goes to the top of the same section (pinned or today) there. Between Spaces of one profile it keeps its live
/// page; to a Space of another profile the app service `ProfileMoves` asks first and loads the page again there.
enum MoveToSpaceMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.tab] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        let targets = context.graph.spaceMoveTargets(for: item)
        guard !targets.isEmpty, owner(of: context) != nil else { return [] }
        let menu = NSMenu(title: "Move to Space")
        for space in targets {
            menu.addItem(
                SidebarMenuItem(title: space.title) { [weak context] in
                    guard let context else { return }
                    move(item, toSpace: space.id, context: context)
                })
        }
        let parent = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return [parent]
    }

    /// Moves tab `item` to Space `target` through the app service `ProfileMoves`, for the menu and for a drop on a
    /// Space's footer icon alike. Returns false when the sidebar has no window to move in.
    @MainActor @discardableResult
    static func move(_ item: SidebarItemID, toSpace target: SidebarSpaceID, context: any SidebarActionContext) -> Bool {
        guard let owner = owner(of: context) else { return false }
        owner.appFeatures.require(ProfileMoves.self).moveTab(item, toSpace: target, in: owner)
        return true
    }

    @MainActor
    private static func owner(of context: any SidebarActionContext) -> BrowserWindowController? {
        (context as? SidebarFeature)?.sidebar.window?.windowController as? BrowserWindowController
    }
}
