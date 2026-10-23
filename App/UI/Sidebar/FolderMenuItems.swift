import AppKit
import BowCore

/// Folder actions in the sidebar's context menus: "New Folder" in the pinned section's header menu (a folder at the
/// end of the pinned tabs) and in a folder's menu (a folder at the end of that folder), then the folder's own
/// "Rename Folder" and its delete items. A new folder starts with its name selected for typing, as a rename does.
///
/// Deleting offers both ways: "Delete Folder and Tabs" asks to confirm and then deletes the folder with all it
/// holds (`SidebarActionContext.deleteWithTabs`), and "Delete Folder, Keep Tabs" moves what the folder holds up to
/// the folder's place in its parent and deletes only the folder. An empty folder has one "Delete Folder" item,
/// which asks nothing.
enum FolderMenuItems: SidebarMenuItems {
    static let newFolderName = "New Folder"

    static var kinds: Set<SidebarItemKind> { [.folder, .section(.pinned)] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        let newFolder = SidebarMenuItem(title: "New Folder") { [weak context] in
            guard let context else { return }
            createFolder(in: item, context: context)
        }
        guard case .folder? = context.graph[item]?.data else { return [newFolder] }
        let rename = SidebarMenuItem(title: "Rename Folder") { [weak context] in context?.beginRename(item) }
        guard let folder = context.graph[item], !folder.childrenIDs.isEmpty else {
            let delete = SidebarMenuItem(title: "Delete Folder") { [weak context] in
                context?.changeSidebar { try $0.apply([.delete(item)]) }
            }
            return [newFolder, rename, .separator(), delete]
        }
        let deleteAll = SidebarMenuItem(title: "Delete Folder and Tabs…") { [weak context] in
            guard let context else { return }
            confirmDelete(item, context: context)
        }
        let keepTabs = SidebarMenuItem(title: "Delete Folder, Keep Tabs") { [weak context] in
            context?.changeSidebar { try $0.apply([.deleteFolderKeepingChildren(item)]) }
        }
        return [newFolder, rename, .separator(), deleteAll, keepTabs]
    }

    /// Adds an empty folder at the end of `parent` (the pinned container or a folder), opening `parent` when it is a
    /// closed folder so the new row shows, and starts renaming it.
    static func createFolder(in parent: SidebarItemID, context: any SidebarActionContext) {
        let folder = SidebarItem.folder(title: newFolderName)
        var changes: [SidebarMutation] = []
        if case .folder(let state)? = context.graph[parent]?.data, !state.isExpanded {
            changes.append(.setFolderExpanded(parent, true))
        }
        changes.append(.insert(folder, parent: parent))
        guard context.changeSidebar({ try $0.apply(changes) }) else { return }
        context.beginRename(folder.id)
    }

    /// Asks before deleting folder `item` with its tabs, naming how many tabs go with it.
    private static func confirmDelete(_ item: SidebarItemID, context: any SidebarActionContext) {
        let graph = context.graph
        let name = graph[item]?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Folder"
        let tabs = graph.items.values.filter { $0.data.isTab && $0.id != item && graph.isDescendant($0.id, of: item) }
        let count = tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs"
        context.confirm(
            "Delete \u{201C}\(name)\u{201D} and its tabs?",
            detail: "The folder and the \(count) inside it will be removed from the sidebar.",
            action: "Delete"
        ) { [weak context] in
            context?.deleteWithTabs(item)
        }
    }
}
