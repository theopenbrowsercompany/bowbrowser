import Foundation

/// What the wizard's screens hold while the person decides: one checkbox per Arc Space, how Spaces come across, and
/// the two optional parts. It turns them into the plan the preview and the import use, so the screens hold no rules.
public struct ArcImportChoices: Equatable, Sendable {
    public var mode: ArcSpaceImportMode = .arcSpaces
    /// The Arc Space ids whose checkbox is ticked. A new choice ticks every Space, as Arc's Spaces are what people come
    /// for.
    public var checkedSpaceIDs: Set<String>
    public var includeFavorites = true
    public var includeUnpinnedTabs = false

    /// Every Space of `result` ticked.
    public init(for result: ArcImportResult) {
        checkedSpaceIDs = Set(result.spaces.map(\.id))
    }

    /// The plan these choices make. Recovered items come along, as the plan's default has them.
    public var plan: ArcImportPlan {
        ArcImportPlan(
            mode: mode, selectedSpaceIDs: checkedSpaceIDs, includeFavorites: includeFavorites,
            includeUnpinnedTabs: includeUnpinnedTabs, includeRecoveredItems: true)
    }

    /// The preview these choices give for `result`, with what `graph` (the sidebar the import lands in) already has.
    public func preview(of result: ArcImportResult, in graph: SidebarGraph?) -> ArcImportPreview {
        ArcImporter.preview(result, plan: plan, existing: graph)
    }

    /// Whether the Space checkboxes apply: skipping Spaces leaves them out, so they are off.
    public var choosesSpaces: Bool { mode != .skipSpaces }
}

/// One line of the preview tree, in order.
public struct ArcImportPreviewRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case space, favorites, section, folder, tab, splitView
    }

    public var depth: Int
    public var kind: Kind
    public var title: String
}

extension ArcImportPreview {
    /// The tree the preview shows, flattened: each Space with its pinned items (folders nested by depth), then its
    /// unpinned tabs under one "Unpinned" line when they come along, then the Favorites. This is the same tree
    /// `ArcImportApplied.importedPinnedTrees(in:)` reads back from the sidebar.
    public var rows: [ArcImportPreviewRow] {
        var rows: [ArcImportPreviewRow] = []
        func add(_ nodes: [ArcImportPreviewNode], depth: Int) {
            for node in nodes {
                let kind: ArcImportPreviewRow.Kind =
                    switch node.kind {
                    case .tab: .tab
                    case .folder: .folder
                    case .splitView: .splitView
                    }
                rows.append(ArcImportPreviewRow(depth: depth, kind: kind, title: node.title))
                add(node.children, depth: depth + 1)
            }
        }
        for space in spaces {
            rows.append(ArcImportPreviewRow(depth: 0, kind: .space, title: space.title))
            add(space.pinned, depth: 1)
            if !space.unpinned.isEmpty {
                rows.append(ArcImportPreviewRow(depth: 1, kind: .section, title: "Unpinned"))
                add(space.unpinned, depth: 2)
            }
        }
        let favorites = favorites.flatMap(\.items)
        if !favorites.isEmpty {
            rows.append(ArcImportPreviewRow(depth: 0, kind: .favorites, title: "Favorites"))
            add(favorites, depth: 1)
        }
        return rows
    }
}
