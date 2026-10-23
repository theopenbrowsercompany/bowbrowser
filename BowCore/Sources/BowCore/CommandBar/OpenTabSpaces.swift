import Foundation

/// Which Space each open tab lives in, read from a snapshot of the sidebar, so the command bar and the tab
/// switcher can show a Space next to every tab and a chosen tab can bring its Space on screen.
///
/// The command bar names tabs by UUID and the sidebar names its items by string. By default a tab's sidebar item
/// ID is its UUID in lowercase, which is how new sidebar IDs are made; the app passes `itemID` if it keeps another
/// mapping. It is a snapshot: build a new value after the sidebar changes. That makes it safe to hand to providers.
public struct OpenTabSpaces: Sendable {
    public typealias ItemIDResolver = @Sendable (UUID) -> SidebarItemID?

    public static let defaultItemID: ItemIDResolver = { SidebarItemID($0.uuidString.lowercased()) }

    private let graph: SidebarGraph
    private let itemID: ItemIDResolver

    public init(graph: SidebarGraph, itemID: @escaping ItemIDResolver = OpenTabSpaces.defaultItemID) {
        self.graph = graph
        self.itemID = itemID
    }

    /// The Space holding `tab`, or nil for a Favorite (no one Space owns it) or a tab the sidebar does not list.
    public func space(of tab: UUID) -> SpaceSummary? {
        guard let item = itemID(tab), let owner = graph.spaceID(containing: item), let space = graph.space(owner)
        else { return nil }
        return SpaceSummary(space)
    }

    /// `tabs` with their Space filled in.
    public func annotated(_ tabs: [OpenTabInfo]) -> [OpenTabInfo] {
        tabs.map {
            var tab = $0
            tab.space = space(of: $0.id)
            return tab
        }
    }
}

/// An open tab source that adds each tab's Space to what another source supplies. `spaces` is called on every
/// request, so it always reflects the sidebar as it is now.
public struct SpaceAnnotatingOpenTabSource: OpenTabSource {
    private let base: any OpenTabSource
    private let spaces: @Sendable () async -> OpenTabSpaces

    public init(_ base: any OpenTabSource, spaces: @escaping @Sendable () async -> OpenTabSpaces) {
        self.base = base
        self.spaces = spaces
    }

    public func openTabs() async -> [OpenTabInfo] {
        let tabs = await base.openTabs()
        return await spaces().annotated(tabs)
    }
}

extension SidebarStore {
    /// Carries out choosing an open tab result: selects the tab, first switching to its Space when it lives in
    /// another one. Returns the Space brought on screen, or nil when the Space on screen did not change. Throws
    /// when the sidebar does not list the tab, in which case nothing changes.
    @discardableResult
    public func selectOpenTab(
        _ tab: UUID, itemID: OpenTabSpaces.ItemIDResolver = OpenTabSpaces.defaultItemID
    ) throws -> SidebarSpaceID? {
        guard let item = itemID(tab) else { throw SidebarStoreError.itemNotFound(SidebarItemID(tab.uuidString)) }
        let before = graph.activeSpaceID
        try selectTab(item)
        return graph.activeSpaceID == before ? nil : graph.activeSpaceID
    }

    /// Carries out a command bar result's action when it switches to an open tab; returns the Space brought on
    /// screen, if any. Does nothing and returns nil for any other action, which the app handles by loading the
    /// address.
    @discardableResult
    public func perform(_ action: CommandBarAction) throws -> SidebarSpaceID? {
        guard case .switchToTab(let tab) = action else { return nil }
        return try selectOpenTab(tab)
    }
}
