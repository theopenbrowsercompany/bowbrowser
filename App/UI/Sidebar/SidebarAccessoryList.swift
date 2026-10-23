// swift-format-ignore-file
// (swift-format would put a one-entry list on one line without its trailing comma, which union merges need.)

/// Every sidebar accessory (`SidebarAccessory`), in slot order: the top slot and the footer each list theirs in the
/// order they appear here. To add one, add its file under `App/UI/Sidebar/` and one line here. One entry per line,
/// each with a trailing comma: git merges this file by union (`.gitattributes`), and `make guards` checks the
/// format and duplicates.
@MainActor
enum SidebarAccessories {
    static let all: [any SidebarAccessory.Type] = [
        DownloadsFooterButton.self,
        ArchiveFooterButton.self,
        SpaceSwitcher.self,
        URLField.self,
    ]
}

/// Every provider of tab row accessories (`SidebarRowAccessory`), first asked first. Same rules as the list above.
@MainActor
enum SidebarRowAccessories {
    static let all: [any SidebarRowAccessory.Type] = [
        BackToPinnedAccessory.self,
    ]
}
