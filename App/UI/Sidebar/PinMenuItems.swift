import AppKit
import BowCore

/// "Pin Tab", "Unpin Tab" and "Replace Pinned URL with Current" for a tab row, with Arc's names. Pinning records the
/// page the tab shows as the page it returns to; unpinning keeps the page it shows; replacing is the only action that
/// changes a pinned tab's saved address after pinning, so browsing never does it silently.
enum PinMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.tab] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        let graph = context.graph
        guard graph[item]?.tab != nil else { return [] }
        guard graph.isPinned(item) else {
            return [
                SidebarMenuItem(title: "Pin Tab") { [weak context] in
                    guard let context else { return }
                    let page = context.livePage(of: item)
                    context.changeSidebar { try $0.pinTab(item, page: page) }
                }
            ]
        }
        var items = [
            SidebarMenuItem(title: "Unpin Tab") { [weak context] in
                guard let context else { return }
                let page = context.livePage(of: item)
                context.changeSidebar { try $0.unpinTab(item, page: page) }
            }
        ]
        if let page = context.livePage(of: item), graph.hasNavigatedAwayFromPinnedURL(item, liveURL: page.url) {
            items.append(
                SidebarMenuItem(title: "Replace Pinned URL with Current") { [weak context] in
                    guard let context, let page = context.livePage(of: item) else { return }
                    context.changeSidebar { try $0.replacePinnedURL(item, with: page) }
                })
        }
        return items
    }
}
