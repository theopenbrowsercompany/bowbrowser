import AppKit
import BowCore

/// Split view items for sidebar rows. A tab row offers "Open in Split View", which shows it beside the active tab
/// (in a new split of the two, or as another pane of the active tab's split), when `SidebarGraph.splitOpening`
/// allows it. A split's row, and each tab inside a split, offers "Separate All Tabs" (Arc's wording), which turns the
/// split back into its tabs in its place; a tab inside a split also offers "Remove from Split View", as its pane's
/// close button does.
enum SplitViewMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.tab, .split] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        let graph = context.graph
        if case .split? = graph[item]?.data { return [separateItem(item, context: context)] }
        if let splitID = graph.splitID(containing: item) {
            return [
                SidebarMenuItem(title: "Remove from Split View") { [weak context] in
                    context?.changeSidebar { try $0.removePane(item) }
                },
                separateItem(splitID, context: context),
            ]
        }
        guard let opening = graph.splitOpening(item, besides: graph.activeTabID) else { return [] }
        return [
            SidebarMenuItem(title: "Open in Split View") { [weak context] in
                guard let context else { return }
                // Checked again: the sidebar may have changed while the menu was open.
                guard context.graph.splitOpening(item, besides: context.graph.activeTabID) == opening else { return }
                context.changeSidebar { store in
                    switch opening {
                    case .create(let tabs): try store.createSplit(from: tabs, focusing: item)
                    case .addPane(let tab, let splitID): try store.addPane(tab, to: splitID)
                    }
                    try store.selectTab(item)
                }
            }
        ]
    }

    private static func separateItem(_ splitID: SidebarItemID, context: any SidebarActionContext) -> NSMenuItem {
        SidebarMenuItem(title: "Separate All Tabs") { [weak context] in
            context?.changeSidebar { try $0.separateSplit(splitID) }
        }
    }
}
