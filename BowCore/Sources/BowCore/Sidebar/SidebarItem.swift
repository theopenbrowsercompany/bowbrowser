import Foundation

/// A stable ID for sidebar records, typed by what it names so item and Space IDs cannot be mixed up.
/// IDs are never reused, so a saved reference can always be checked.
public struct SidebarID<Kind>: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

    /// A new random ID.
    public static func make() -> SidebarID { SidebarID(UUID().uuidString.lowercased()) }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: SidebarID, rhs: SidebarID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public enum SidebarItemIDKind {}
public enum SidebarSpaceIDKind {}
public typealias SidebarItemID = SidebarID<SidebarItemIDKind>
public typealias SidebarSpaceID = SidebarID<SidebarSpaceIDKind>

extension SidebarID where Kind == SidebarItemIDKind {
    /// The folder that collects items the cleanup pass found without a valid place in the sidebar.
    public static var recentlyRecovered: SidebarItemID { "bow.sidebar.recently-recovered" }
}

/// A saved tab. Its saved address and title are the durable truth: the page a tab shows while it is open lives in
/// the tab model at runtime and reaches this record only through an explicit `setSavedPage` mutation, so a pinned tab
/// can always return to the page it was pinned on. There is deliberately no field for the live address.
public struct SidebarTab: Codable, Hashable, Sendable {
    /// The address as saved, kept as text so saving never normalizes what the person pinned.
    public var savedURL: String
    public var savedTitle: String

    public init(savedURL: String, savedTitle: String = "") {
        self.savedURL = savedURL
        self.savedTitle = savedTitle
    }
}

/// A folder of tabs, splits and other folders, nested to any depth.
public struct SidebarFolder: Codable, Hashable, Sendable {
    public var isExpanded: Bool

    public init(isExpanded: Bool = true) { self.isExpanded = isExpanded }
}

/// Tabs shown side by side. Its children are always tabs.
public struct SidebarSplit: Codable, Hashable, Sendable {
    public enum Orientation: String, Codable, Sendable {
        case horizontal
        case vertical
    }

    public var orientation: Orientation

    public init(orientation: Orientation = .horizontal) { self.orientation = orientation }
}

/// The root of one section of the sidebar. Containers have no parent and are owned by a Space or by a profile's
/// Favorites.
public struct SidebarContainer: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case favorites
        case pinned
        case unpinned
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }
}

/// What a sidebar item is.
public enum SidebarItemData: Hashable, Sendable {
    case tab(SidebarTab)
    case folder(SidebarFolder)
    case split(SidebarSplit)
    case container(SidebarContainer)

    public var isTab: Bool {
        if case .tab = self { return true }
        return false
    }

    public var isContainer: Bool {
        if case .container = self { return true }
        return false
    }

    /// Whether an item of this kind may hold `child`. Tabs hold nothing, splits hold only tabs, containers are roots,
    /// and a Favorites section holds only tabs.
    public func canHold(_ child: SidebarItemData) -> Bool {
        switch (self, child) {
        case (_, .container): return false
        case (.tab, _): return false
        case (.split, .tab): return true
        case (.split, _): return false
        case (.container(let container), _): return container.kind != .favorites || child.isTab
        case (.folder, _): return true
        }
    }
}

extension SidebarItemData: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, tab, folder, split, container
    }

    private enum Kind: String, Codable {
        case tab, folder, split, container
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .tab: self = .tab(try values.decode(SidebarTab.self, forKey: .tab))
        case .folder: self = .folder(try values.decode(SidebarFolder.self, forKey: .folder))
        case .split: self = .split(try values.decode(SidebarSplit.self, forKey: .split))
        case .container: self = .container(try values.decode(SidebarContainer.self, forKey: .container))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let tab):
            try values.encode(Kind.tab, forKey: .kind)
            try values.encode(tab, forKey: .tab)
        case .folder(let folder):
            try values.encode(Kind.folder, forKey: .kind)
            try values.encode(folder, forKey: .folder)
        case .split(let split):
            try values.encode(Kind.split, forKey: .kind)
            try values.encode(split, forKey: .split)
        case .container(let container):
            try values.encode(Kind.container, forKey: .kind)
            try values.encode(container, forKey: .container)
        }
    }
}

/// One node of the sidebar's flat graph. The hierarchy is recorded twice, as the parent's ordered `childrenIDs` and
/// as the child's `parentID`; the store keeps both in step and the cleanup pass repairs any disagreement.
public struct SidebarItem: Codable, Hashable, Sendable {
    public var id: SidebarItemID
    /// A custom name (a folder's name, or a pinned tab the person renamed). Nil shows the default name.
    public var title: String?
    public var parentID: SidebarItemID?
    public var childrenIDs: [SidebarItemID]
    public var data: SidebarItemData

    public init(
        id: SidebarItemID = .make(),
        title: String? = nil,
        parentID: SidebarItemID? = nil,
        childrenIDs: [SidebarItemID] = [],
        data: SidebarItemData
    ) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.childrenIDs = childrenIDs
        self.data = data
    }

    public static func tab(id: SidebarItemID = .make(), url: String, title: String = "", customTitle: String? = nil)
        -> SidebarItem
    {
        SidebarItem(id: id, title: customTitle, data: .tab(SidebarTab(savedURL: url, savedTitle: title)))
    }

    public static func folder(id: SidebarItemID = .make(), title: String) -> SidebarItem {
        SidebarItem(id: id, title: title, data: .folder(SidebarFolder()))
    }

    public static func split(id: SidebarItemID = .make(), orientation: SidebarSplit.Orientation = .horizontal)
        -> SidebarItem
    {
        SidebarItem(id: id, data: .split(SidebarSplit(orientation: orientation)))
    }

    public var tab: SidebarTab? {
        if case .tab(let tab) = data { return tab }
        return nil
    }
}

/// A Space: a named sidebar with its own pinned and unpinned sections.
public struct SidebarSpace: Codable, Hashable, Sendable {
    public var id: SidebarSpaceID
    public var title: String
    public var pinnedContainerID: SidebarItemID
    public var unpinnedContainerID: SidebarItemID
    /// The profile this Space shows. Spaces from files written before profiles existed use the default profile.
    public var profileID: SidebarProfileID
    /// The tab that was selected when the Space was last left, so coming back selects it again. It may name a tab
    /// that has since moved or closed; readers check it before use.
    public var lastSelectedTabID: SidebarItemID?
    /// The picture next to the Space's name. Nil shows none.
    public var icon: SpaceIcon?
    /// The color theme. Nil means the default theme (see `resolvedTheme`).
    public var theme: SpaceTheme?

    public init(
        id: SidebarSpaceID,
        title: String,
        pinnedContainerID: SidebarItemID,
        unpinnedContainerID: SidebarItemID,
        profileID: SidebarProfileID = .default,
        lastSelectedTabID: SidebarItemID? = nil,
        icon: SpaceIcon? = nil,
        theme: SpaceTheme? = nil
    ) {
        self.id = id
        self.title = title
        self.pinnedContainerID = pinnedContainerID
        self.unpinnedContainerID = unpinnedContainerID
        self.profileID = profileID
        self.lastSelectedTabID = lastSelectedTabID
        self.icon = icon
        self.theme = theme
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, pinnedContainerID, unpinnedContainerID, profileID, lastSelectedTabID, icon, theme
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(SidebarSpaceID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        pinnedContainerID = try values.decode(SidebarItemID.self, forKey: .pinnedContainerID)
        unpinnedContainerID = try values.decode(SidebarItemID.self, forKey: .unpinnedContainerID)
        profileID = (try? values.decodeIfPresent(SidebarProfileID.self, forKey: .profileID)) ?? .default
        lastSelectedTabID = try? values.decodeIfPresent(SidebarItemID.self, forKey: .lastSelectedTabID)
        // Files from before icons and themes have neither; a value this build cannot read counts as unset.
        icon = try? values.decodeIfPresent(SpaceIcon.self, forKey: .icon)
        theme = try? values.decodeIfPresent(SpaceTheme.self, forKey: .theme)
    }
}
