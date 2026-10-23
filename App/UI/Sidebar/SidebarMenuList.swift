// swift-format-ignore-file
// (swift-format would put a one-entry list on one line without its trailing comma, which union merges need.)

/// Every provider of sidebar context menu items, in menu order. To add one, add its file under `App/UI/Sidebar/`
/// and one line here. One entry per line, each with a trailing comma: git merges this file by union
/// (`.gitattributes`), and `make guards` checks the format and duplicates.
@MainActor
enum SidebarMenus {
    static let all: [any SidebarMenuItems.Type] = [
        CloseTabMenuItems.self,
        PinMenuItems.self,
        FolderMenuItems.self,
        FavoritesMenuItems.self,
        SpaceProfileMenuItems.self,
        SpaceThemeMenuItems.self,
    ]
}
