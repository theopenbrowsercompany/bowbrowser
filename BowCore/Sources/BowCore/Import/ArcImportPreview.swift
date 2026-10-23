import Foundation

/// One row of the import preview tree: what the sidebar will show once the import is applied.
public struct ArcImportPreviewNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case tab
        case folder
        case splitView
    }

    public var kind: Kind
    /// The name shown: a folder's name, or a tab's custom name, saved page title or address, in that order.
    public var title: String
    /// The name the person gave a tab in Arc; nil when the tab shows its page title.
    public var customName: String?
    public var url: String?
    public var savedTitle: String
    /// Arc's folder icon. Bow's sidebar has no folder icons yet, so it shows in the preview but is not stored.
    public var icon: ArcImportIcon?
    public var orientation: SidebarSplit.Orientation?
    public var children: [ArcImportPreviewNode]

    public var isEmptyFolder: Bool { kind == .folder && children.isEmpty }

    static func displayTitle(custom: String?, saved: String, url: String) -> String {
        if let custom, !custom.isEmpty { return custom }
        return saved.isEmpty ? url : saved
    }

    init(_ tab: ArcImportTab) {
        kind = .tab
        customName = tab.customName
        url = tab.url
        savedTitle = tab.savedTitle ?? ""
        title = Self.displayTitle(custom: tab.customName, saved: tab.savedTitle ?? "", url: tab.url)
        icon = nil
        orientation = nil
        children = []
    }

    init(
        kind: Kind, title: String, icon: ArcImportIcon? = nil, orientation: SidebarSplit.Orientation? = nil,
        children: [ArcImportPreviewNode]
    ) {
        self.kind = kind
        self.title = title
        customName = nil
        url = nil
        savedTitle = ""
        self.icon = icon
        self.orientation = orientation
        self.children = children
    }

    init(_ node: ArcImportNode) {
        switch node {
        case .tab(let tab):
            self.init(tab)
        case .folder(let folder):
            self.init(kind: .folder, title: folder.name, icon: folder.icon, children: folder.children.map(Self.init))
        case .splitView(let split):
            self.init(
                kind: .splitView, title: "Split view",
                orientation: split.orientation.map { $0 == .vertical ? .vertical : .horizontal } ?? .horizontal,
                children: split.panes.map(Self.init))
        }
    }

    /// The same node without folder icons, for comparing a preview with what the sidebar stored.
    public var withoutIcons: ArcImportPreviewNode {
        var copy = self
        copy.icon = nil
        copy.children = children.map(\.withoutIcons)
        return copy
    }

    /// Every tab in this node, split view panes included, in order.
    var tabs: [ArcImportPreviewNode] {
        kind == .tab ? [self] : children.flatMap(\.tabs)
    }
}

/// What importing would put in the sidebar, in sidebar order, without changing anything.
public struct ArcImportPreview: Equatable, Sendable {
    public struct SpaceEntry: Equatable, Sendable {
        /// The Arc Space id.
        public var arcID: String
        public var title: String
        public var icon: ArcImportIcon?
        public var profile: ArcImportProfileTarget
        /// Pinned items, then any recovered items as a last folder.
        public var pinned: [ArcImportPreviewNode]
        /// Empty unless the plan includes unpinned tabs.
        public var unpinned: [ArcImportPreviewNode]
    }

    public struct FavoritesEntry: Equatable, Sendable {
        public var profile: ArcImportProfileTarget
        /// The Arc Space whose own profile gets this copy, when each Space has its own profile.
        public var forArcSpaceID: String?
        /// Favorites are tabs only: a split view in Arc's Favorites arrives as its separate tabs.
        public var items: [ArcImportPreviewNode]
    }

    /// Something Arc has that this import does not bring, because of the plan and not because of the file.
    public struct Omission: Equatable, Sendable {
        public enum Reason: String, Equatable, Sendable {
            case spaceNotSelected
            case spacesSkipped
            case favoritesWithoutSpace
            case favoritesNotIncluded
            case recoveredItemsWithoutSpace
            case recoveredItemsNotIncluded
            case unpinnedTabsNotIncluded
            case favoritesAlreadyThere

            public var summary: String {
                switch self {
                case .spaceNotSelected: "Space not selected"
                case .spacesSkipped: "Spaces are skipped"
                case .favoritesWithoutSpace: "Favorites belong to a profile no brought Space uses"
                case .favoritesNotIncluded: "Favorites are not included"
                case .recoveredItemsWithoutSpace: "Recovered items need a Space to go into"
                case .recoveredItemsNotIncluded: "Recovered items are not included"
                case .unpinnedTabsNotIncluded: "Unpinned tabs are not included"
                case .favoritesAlreadyThere: "Already in your Favorites"
                }
            }
        }

        public var reason: Reason
        public var label: String
        /// How many tabs the omission covers.
        public var tabs: Int
    }

    public struct Counts: Equatable, Sendable {
        public var spaces = 0
        public var folders = 0
        public var emptyFolders = 0
        public var maxFolderDepth = 0
        public var tabs = 0
        public var splitViews = 0
        public var customNamedTabs = 0
        public var favorites = 0
    }

    public var mode: ArcSpaceImportMode
    public var spaces: [SpaceEntry]
    public var favorites: [FavoritesEntry]
    public var omissions: [Omission]
    /// What the parser already left out of the file, passed through from the report.
    public var skippedByImporter: [ArcImportSkipped]

    /// Everything the import would bring. `tabs` counts pinned, unpinned and Favorites, split view panes included.
    public var counts: Counts {
        var counts = Counts()
        counts.spaces = spaces.count
        func visit(_ nodes: [ArcImportPreviewNode], depth: Int) {
            for node in nodes {
                switch node.kind {
                case .tab:
                    counts.tabs += 1
                    if node.customName != nil { counts.customNamedTabs += 1 }
                case .folder:
                    counts.folders += 1
                    if node.children.isEmpty { counts.emptyFolders += 1 }
                    counts.maxFolderDepth = max(counts.maxFolderDepth, depth + 1)
                    visit(node.children, depth: depth + 1)
                case .splitView:
                    counts.splitViews += 1
                    visit(node.children, depth: depth)
                }
            }
        }
        for space in spaces {
            visit(space.pinned, depth: 0)
            visit(space.unpinned, depth: 0)
        }
        for entry in favorites {
            counts.favorites += entry.items.count
            visit(entry.items, depth: 0)
        }
        return counts
    }

    public var isEmpty: Bool {
        spaces.isEmpty && favorites.allSatisfy { $0.items.isEmpty }
    }

    /// The line the end to end run prints: the deepest folder chain of the brought Spaces with the first tab inside
    /// it, and the number of Favorites, for example `tree=client/project/phase/[A] favorites=4`.
    public var summaryLine: String {
        Self.summaryLine(
            pinnedTrees: spaces.map(\.pinned),
            favoritesCount: favorites.reduce(0) { $0 + $1.items.count })
    }

    static func summaryLine(pinnedTrees: [[ArcImportPreviewNode]], favoritesCount: Int) -> String {
        var best: (path: [String], tab: String?) = ([], nil)
        func visit(_ nodes: [ArcImportPreviewNode], path: [String]) {
            for node in nodes where node.kind == .folder {
                let here = path + [node.title]
                if here.count > best.path.count {
                    best = (here, node.children.first { $0.kind == .tab }?.title)
                }
                visit(node.children, path: here)
            }
        }
        for tree in pinnedTrees { visit(tree, path: []) }
        var tree = best.path.isEmpty ? "none" : best.path.joined(separator: "/")
        if !best.path.isEmpty, let tab = best.tab { tree += "/[\(tab)]" }
        return "tree=\(tree) favorites=\(favoritesCount)"
    }

    /// A readable summary for the preview screen, above the tree.
    public var text: String {
        let counts = counts
        var lines = [
            "Spaces: \(counts.spaces)",
            "Folders: \(counts.folders) (\(counts.emptyFolders) empty, nested up to \(counts.maxFolderDepth) deep)",
            "Tabs: \(counts.tabs) (\(counts.customNamedTabs) with custom names)",
            "Favorites: \(counts.favorites)",
            "Split views: \(counts.splitViews)",
        ]
        if !omissions.isEmpty {
            lines.append("Not brought because of your choices: \(omissions.count)")
            for omission in omissions { lines.append("  \(omission.label): \(omission.reason.summary)") }
        }
        if !skippedByImporter.isEmpty { lines.append("Left out of the file: \(skippedByImporter.count)") }
        return lines.joined(separator: "\n")
    }
}

extension ArcImporter {
    /// Builds what `plan` would bring from `result`. It reads nothing and changes nothing.
    ///
    /// With `existing` (the sidebar the import would land in), Favorites the profile already has at the same address
    /// are left out and listed, so a second import does not repeat them and the preview shows what will arrive.
    public static func preview(
        _ result: ArcImportResult, plan: ArcImportPlan = ArcImportPlan(), existing: SidebarGraph? = nil
    ) -> ArcImportPreview {
        var omissions: [ArcImportPreview.Omission] = []
        func tabCount(_ nodes: [ArcImportNode]) -> Int { nodes.map(ArcImportPreviewNode.init).flatMap(\.tabs).count }

        // 1. Which Spaces come along.
        var chosen: [ArcImportSpace] = []
        for space in result.spaces {
            let everything = tabCount(space.pinned + space.unpinned)
            if plan.mode == .skipSpaces {
                omissions.append(.init(reason: .spacesSkipped, label: space.title, tabs: everything))
            } else if plan.selectedSpaceIDs?.contains(space.id) ?? true {
                chosen.append(space)
            } else {
                omissions.append(.init(reason: .spaceNotSelected, label: space.title, tabs: everything))
            }
        }

        // 2. The Spaces themselves.
        var spaceEntries: [ArcImportPreview.SpaceEntry] = []
        for (index, space) in chosen.enumerated() {
            let title = space.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var pinned = space.pinned.map(ArcImportPreviewNode.init)
            if index == 0, plan.includeRecoveredItems, !result.recovered.isEmpty {
                pinned.append(
                    ArcImportPreviewNode(
                        kind: .folder, title: "Recovered from Arc",
                        children: result.recovered.map(ArcImportPreviewNode.init)))
            }
            var unpinned: [ArcImportPreviewNode] = []
            if plan.includeUnpinnedTabs {
                unpinned = space.unpinned.map(ArcImportPreviewNode.init)
            } else if !space.unpinned.isEmpty {
                omissions.append(
                    .init(reason: .unpinnedTabsNotIncluded, label: space.title, tabs: tabCount(space.unpinned)))
            }
            spaceEntries.append(
                .init(
                    arcID: space.id, title: title.isEmpty ? "Imported Space \(index + 1)" : title, icon: space.icon,
                    profile: plan.mode == .spacesAsProfiles ? .separateProfile : .mapping(space.profile),
                    pinned: pinned, unpinned: unpinned))
        }
        if !result.recovered.isEmpty {
            if chosen.isEmpty {
                omissions.append(
                    .init(
                        reason: .recoveredItemsWithoutSpace, label: "Recovered items", tabs: tabCount(result.recovered))
                )
            } else if !plan.includeRecoveredItems {
                omissions.append(
                    .init(
                        reason: .recoveredItemsNotIncluded, label: "Recovered items", tabs: tabCount(result.recovered)))
            }
        }

        // 3. Favorites, grouped by Arc profile.
        var favoriteEntries: [ArcImportPreview.FavoritesEntry] = []
        for list in result.favorites {
            let tabs = list.items.map(ArcImportPreviewNode.init).flatMap(\.tabs)
            guard !tabs.isEmpty else { continue }
            let label = "Favorites of \(profileLabel(list.profile))"
            guard plan.includeFavorites else {
                omissions.append(.init(reason: .favoritesNotIncluded, label: label, tabs: tabs.count))
                continue
            }
            let owners = chosen.filter { $0.profile == list.profile }
            switch plan.mode {
            case .skipSpaces:
                if list.profile == .default {
                    favoriteEntries.append(.init(profile: .defaultProfile, forArcSpaceID: nil, items: tabs))
                } else {
                    omissions.append(.init(reason: .favoritesWithoutSpace, label: label, tabs: tabs.count))
                }
            case .spacesAsProfiles:
                if owners.isEmpty {
                    omissions.append(.init(reason: .favoritesWithoutSpace, label: label, tabs: tabs.count))
                }
                for owner in owners {
                    favoriteEntries.append(.init(profile: .separateProfile, forArcSpaceID: owner.id, items: tabs))
                }
            case .arcSpaces:
                if owners.isEmpty {
                    omissions.append(.init(reason: .favoritesWithoutSpace, label: label, tabs: tabs.count))
                } else {
                    favoriteEntries.append(.init(profile: .mapping(list.profile), forArcSpaceID: nil, items: tabs))
                }
            }
        }

        if let existing {
            var kept: [ArcImportPreview.FavoritesEntry] = []
            for var entry in favoriteEntries {
                let (fresh, repeated) = withoutKnownFavorites(entry.items, for: entry.profile, in: existing)
                if !repeated.isEmpty {
                    omissions.append(
                        .init(
                            reason: .favoritesAlreadyThere, label: repeated.map(\.title).joined(separator: ", "),
                            tabs: repeated.count))
                }
                entry.items = fresh
                if !fresh.isEmpty { kept.append(entry) }
            }
            favoriteEntries = kept
        }

        return ArcImportPreview(
            mode: plan.mode, spaces: spaceEntries, favorites: favoriteEntries, omissions: omissions,
            skippedByImporter: result.report.skipped)
    }

    /// Splits Favorites into those the profile's Favorites section does not have yet (by saved address) and those it
    /// has. A profile that has no section yet, and a profile made for one Space, have none.
    static func withoutKnownFavorites(
        _ items: [ArcImportPreviewNode], for target: ArcImportProfileTarget, in graph: SidebarGraph
    ) -> (fresh: [ArcImportPreviewNode], repeated: [ArcImportPreviewNode]) {
        let profile: SidebarProfileID
        switch target {
        case .defaultProfile: profile = .default
        case .arcProfile(let id): profile = id
        case .separateProfile: return (items, [])
        }
        // Only what the sidebar already has counts: two Favorites at one address inside the file both come.
        let known = Set(graph.favoriteIDs(for: profile).compactMap { graph.items[$0]?.tab?.savedURL })
        var fresh: [ArcImportPreviewNode] = []
        var repeated: [ArcImportPreviewNode] = []
        for item in items {
            if let url = item.url, known.contains(url) { repeated.append(item) } else { fresh.append(item) }
        }
        return (fresh, repeated)
    }

    private static func profileLabel(_ profile: ArcImportProfile) -> String {
        switch profile {
        case .default: "the default profile"
        case .custom(let basename): "profile \(basename)"
        }
    }
}
