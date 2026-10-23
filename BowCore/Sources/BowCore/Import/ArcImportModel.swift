import Foundation

/// The Chromium profile an Arc Space or Favorites list belongs to.
public enum ArcImportProfile: Hashable, Sendable {
    case `default`
    case custom(directoryBasename: String)
}

/// A Space or folder icon: an emoji or one of Arc's named symbols.
public enum ArcImportIcon: Equatable, Sendable {
    case emoji(String)
    case symbol(String)
}

/// The parts of a Space's window theme the importer carries over. Colors are not mapped yet.
public struct ArcImportTheme: Equatable, Sendable {
    /// Arc's background style, such as `blendedGradient`.
    public var style: String?
    /// Arc's window appearance, such as `light` or `dark`.
    public var appearance: String?
}

public struct ArcImportTab: Equatable, Sendable {
    public var id: String
    public var url: String
    /// The page title Arc saved with the tab.
    public var savedTitle: String?
    /// A name the person gave the pinned tab; nil when the tab shows its page title.
    public var customName: String?
}

public struct ArcImportFolder: Equatable, Sendable {
    public var id: String
    public var name: String
    public var icon: ArcImportIcon?
    /// Tabs, split views and subfolders in sidebar order. An empty folder stays empty.
    public var children: [ArcImportNode]
}

public struct ArcImportSplitView: Equatable, Sendable {
    public enum Orientation: String, Equatable, Sendable {
        case horizontal
        case vertical
    }

    public var id: String
    public var panes: [ArcImportTab]
    public var orientation: Orientation?
    public var widthFactors: [Double]
    /// Index into `panes` of the pane that had focus, when Arc recorded one.
    public var focusedPane: Int?
}

public enum ArcImportNode: Equatable, Sendable {
    case tab(ArcImportTab)
    case folder(ArcImportFolder)
    case splitView(ArcImportSplitView)
}

public struct ArcImportSpace: Equatable, Sendable {
    public var id: String
    public var title: String
    public var icon: ArcImportIcon?
    public var theme: ArcImportTheme?
    public var profile: ArcImportProfile
    /// Pinned items in sidebar order; loose pinned tabs stay at the top level.
    public var pinned: [ArcImportNode]
    /// The Space's unpinned ("today") items from every unpinned container it points to.
    public var unpinned: [ArcImportNode]
}

public struct ArcImportFavorites: Equatable, Sendable {
    public var profile: ArcImportProfile
    public var items: [ArcImportNode]
}

/// Something the importer left out or repaired, and why.
public struct ArcImportSkipped: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case liveFolder
        case easel
        case note
        case sharedObject
        case unsupportedItem
        case tabWithoutURL
        case emptySplitView
        case singleTabSplitView
        case extraSplitViewPanes
        case orphan
        case unreachable
        case missingItem
        case duplicateReference
        case nestedTooDeep
        case unsupportedContainer
        case malformedEntry
        case idMismatch
        case duplicateID

        public var summary: String {
            switch self {
            case .liveFolder: "Live Folders are not imported"
            case .easel: "Easels are not imported"
            case .note: "Notes are not imported"
            case .sharedObject: "Shared items are not imported"
            case .unsupportedItem: "Unsupported kind of item"
            case .tabWithoutURL: "Tab has no saved address"
            case .emptySplitView: "Split view has no tabs"
            case .singleTabSplitView: "Split view has one tab and imports as a plain tab"
            case .extraSplitViewPanes: "Split view has more than four tabs; the extra tabs import as plain tabs"
            case .orphan: "Item belongs to no folder or Space"
            case .unreachable: "Item is not reachable from any Space or Favorites"
            case .missingItem: "Referenced item is missing from the file"
            case .duplicateReference: "Item appears in more than one place"
            case .nestedTooDeep: "Folders are nested too deeply"
            case .unsupportedContainer: "Container kind is not imported"
            case .malformedEntry: "Entry could not be read"
            case .idMismatch: "Entry key does not match its id"
            case .duplicateID: "Two entries share one id"
            }
        }
    }

    public var reason: Reason
    /// The Arc id involved, when there is one.
    public var itemID: String?
    /// A title or other text that helps a person recognize the item.
    public var label: String?
}

/// What an import would bring in, without changing anything.
public struct ArcImportReport: Equatable, Sendable {
    public var spaces: Int
    public var folders: Int
    public var emptyFolders: Int
    /// Deepest folder nesting: 0 without folders, 1 for folders at the top level.
    public var maxFolderDepth: Int
    public var pinnedTabs: Int
    public var unpinnedTabs: Int
    public var favorites: Int
    public var splitViews: Int
    public var customNamedTabs: Int
    /// Orphaned top level items rescued into `ArcImportResult.recovered`.
    public var recoveredItems: Int
    /// Tabs inside the recovered items, split view panes included. Not part of `pinnedTabs`.
    public var recoveredTabs: Int
    public var skipped: [ArcImportSkipped]

    /// The one line the end to end run prints, for example `spaces=3 folders=5 depth=3 pinned=18`.
    public var summaryLine: String {
        "spaces=\(spaces) folders=\(folders) depth=\(maxFolderDepth) pinned=\(pinnedTabs)"
    }

    /// A readable multi-line report for a preview screen or a log.
    public var text: String {
        var lines = [
            "Spaces: \(spaces)",
            "Folders: \(folders) (\(emptyFolders) empty, nested up to \(maxFolderDepth) deep)",
            "Pinned tabs: \(pinnedTabs) (\(customNamedTabs) with custom names)",
            "Unpinned tabs: \(unpinnedTabs)",
            "Favorites: \(favorites)",
            "Split views: \(splitViews)",
        ]
        if recoveredItems > 0 { lines.append("Recovered: \(recoveredItems) items with \(recoveredTabs) tabs") }
        if skipped.isEmpty {
            lines.append("Skipped: none")
        } else {
            lines.append("Skipped: \(skipped.count)")
            let grouped = Dictionary(grouping: skipped, by: \.reason)
            for reason in grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                lines.append("  \(grouped[reason]?.count ?? 0) x \(reason.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct ArcImportResult: Equatable, Sendable {
    public var spaces: [ArcImportSpace]
    /// Favorites per profile, in file order.
    public var favorites: [ArcImportFavorites]
    /// Orphaned items kept when the orphan policy is `collect`; empty otherwise.
    public var recovered: [ArcImportNode]
    public var report: ArcImportReport
}

public struct ArcImportOptions: Equatable, Sendable {
    public enum OrphanPolicy: Equatable, Sendable {
        /// Keep orphans in `ArcImportResult.recovered`, as Arc's own "Recently recovered" folder does.
        case collect
        /// Leave orphans out and list them in the report.
        case drop
    }

    public var orphans: OrphanPolicy

    public init(orphans: OrphanPolicy = .collect) {
        self.orphans = orphans
    }
}

public enum ArcImportError: Error, Equatable, Sendable {
    /// The data is not JSON.
    case invalidJSON
    /// The JSON has no `sidebar.containers`, so it is not an Arc sidebar file.
    case notAnArcSidebar
}
