// swift-format-ignore-file
// (swift-format would put a one-entry list on one line without its trailing comma, which union merges need.)

/// Every sidebar drop rule. To add one, add its file under `App/UI/Sidebar/` and one line here. One entry per line,
/// each with a trailing comma: git merges this file by union (`.gitattributes`), and `make guards` checks the
/// format and duplicates.
@MainActor
enum SidebarDropValidators {
    static let all: [any SidebarDropValidator.Type] = [
        StructureDropValidator.self,
        FavoritesDropValidator.self,
        SplitTabDropValidator.self,
    ]
}
