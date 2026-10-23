import AppKit
import BowCore

/// What a sidebar item is, for choosing its context menu items.
enum SidebarItemKind: Sendable {
    case tab
    case folder
    case split
    case favorite

    /// The kind of `id` in `graph`, or nil for a section or an unknown item.
    init?(of id: SidebarItemID, in graph: SidebarGraph) {
        switch graph[id]?.data {
        case .tab?: self = graph.isInFavorites(id) ? .favorite : .tab
        case .folder?: self = .folder
        case .split?: self = .split
        case .container?, nil: return nil
        }
    }
}

/// What sidebar actions (context menu items, drops) may do to the window: read its sidebar, select or close a tab,
/// and change the store. The sidebar feature provides it.
@MainActor
protocol SidebarActionContext: AnyObject {
    /// The window's committed sidebar.
    var graph: SidebarGraph { get }
    /// Makes tab `item` active and shows it.
    func select(_ item: SidebarItemID)
    /// Closes tab `item` as its close button does.
    func close(_ item: SidebarItemID)
    /// Runs `body` on the store, then brings the window up to date. Returns whether the change went through.
    @discardableResult
    func changeSidebar(_ body: (SidebarStore) throws -> Void) -> Bool
    /// The page tab `item` shows right now, nil while it has not loaded.
    func livePage(of item: SidebarItemID) -> (url: URL, title: String)?
}

/// Context menu items for sidebar items of some kinds.
///
/// Extension point: a new set of items (Pin and Unpin, folder actions, Favorite actions) is one new file with a type
/// conforming to this protocol plus one line in `SidebarMenus.all`. The menu lists each provider's items in list
/// order, with a separator between providers.
@MainActor
protocol SidebarMenuItems {
    /// The kinds of item this provider adds to.
    static var kinds: Set<SidebarItemKind> { get }
    /// The items for `item`; empty adds nothing.
    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem]
}

/// Every provider of sidebar context menu items, in menu order. One entry per line.
@MainActor
enum SidebarMenus {
    // swift-format-ignore
    // (a one-entry list keeps its trailing comma, so each provider stays one line.)
    static let all: [any SidebarMenuItems.Type] = [
        CloseTabMenuItems.self,
    ]

    /// The context menu of `item`: each provider's items for its kind, separated by provider.
    static func menu(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        guard let kind = SidebarItemKind(of: item, in: context.graph) else { return [] }
        var result: [NSMenuItem] = []
        for provider in all where provider.kinds.contains(kind) {
            let items = provider.menuItems(for: item, context: context)
            guard !items.isEmpty else { continue }
            if !result.isEmpty { result.append(.separator()) }
            result += items
        }
        return result
    }
}

/// A menu item that runs a closure, so providers need no target object of their own.
@MainActor
final class SidebarMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run(_ sender: Any?) {
        handler()
    }
}

/// "Close Tab" for a tab row, as its close button does (a pinned tab only unloads and stays).
enum CloseTabMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.tab] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        [SidebarMenuItem(title: "Close Tab") { [weak context] in context?.close(item) }]
    }
}
