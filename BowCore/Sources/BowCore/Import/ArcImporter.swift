import Foundation

/// Reads Arc's `StorableSidebar.json` into the importer's own model and a dry run report.
///
/// The importer never touches the file system: the caller hands it the bytes of a file the
/// person chose, and nothing is written anywhere. Only `sidebar.containers` is read; sync
/// bookkeeping and the rest of the file are ignored.
public enum ArcImporter {
    /// Parses the file and returns the mapped Spaces, Favorites and the report.
    public static func parse(_ data: Data, options: ArcImportOptions = ArcImportOptions()) throws -> ArcImportResult {
        let root: ArcJSON
        do {
            root = try JSONDecoder().decode(ArcJSON.self, from: data)
        } catch {
            throw ArcImportError.invalidJSON
        }
        guard let containers = root["sidebar"]?["containers"]?.array else {
            throw ArcImportError.notAnArcSidebar
        }
        var builder = ArcImportBuilder(options: options)
        for container in containers {
            builder.read(container: container)
        }
        return builder.finish()
    }

    /// The report alone: what an import would bring in and what it would skip.
    public static func dryRun(_ data: Data, options: ArcImportOptions = ArcImportOptions()) throws -> ArcImportReport {
        try parse(data, options: options).report
    }
}

private struct RawItem {
    var id: String
    var title: String?
    var parentID: String?
    var childrenIDs: [String]
    /// The case of Arc's tagged `data` union, such as `tab` or `list`.
    var kind: String
    var payload: ArcJSON
}

private struct RawSpace {
    var id: String
    var json: ArcJSON
}

private struct ArcImportBuilder {
    static let knownContainerKinds: Set<String> = ["global", "incognito", "littleBrowser", "standalone"]
    static let knownItemKinds = [
        "tab", "list", "itemContainer", "splitView", "tabGroup", "easel", "arcDocument", "sharedObject",
        "instantLinks", "welcomeToArc", "archiveContent", "download", "arcSearch",
    ]
    static let maxFolderDepth = 64

    let options: ArcImportOptions
    var skipped: [ArcImportSkipped] = []

    var itemOrder: [String] = []
    var items: [String: RawItem] = [:]
    var childrenByParent: [String: [String]] = [:]
    var rawSpaces: [RawSpace] = []
    var topApps: [(profile: ArcImportProfile, containerID: String)] = []
    var visited: Set<String> = []

    init(options: ArcImportOptions) {
        self.options = options
    }

    // MARK: Reading containers

    mutating func read(container: ArcJSON) {
        guard let object = container.object else {
            skip(.malformedEntry, label: "container")
            return
        }
        let hasContent = object["items"] != nil || object["spaces"] != nil
        let kind =
            object["type"]?.caseName
            ?? Self.knownContainerKinds.sorted().first { object[$0] != nil }
        if let kind, kind != "global" {
            if hasContent { skip(.unsupportedContainer, label: kind) }
            return
        }
        // A container without a kind and without sidebar content is file bookkeeping.
        guard hasContent || kind != nil else { return }

        readItems(object["items"])
        readSpaces(object["spaces"])
        readTopApps(object)
    }

    mutating func readItems(_ json: ArcJSON?) {
        guard let json else { return }
        guard let (pairs, droppedTail) = json.keyValuePairs() else {
            skip(.malformedEntry, label: "items")
            return
        }
        if droppedTail { skip(.malformedEntry, label: "items: odd number of elements") }
        for (key, value) in pairs {
            guard let id = key.string, let object = value.object else {
                skip(.malformedEntry, label: "item")
                continue
            }
            if let declared = object["id"]?.string, declared != id {
                skip(.idMismatch, itemID: id)
                continue
            }
            guard items[id] == nil else {
                skip(.duplicateID, itemID: id)
                continue
            }
            let data = object["data"]?.object ?? [:]
            let kind = Self.knownItemKinds.first { data[$0] != nil } ?? data.keys.min() ?? "unknown"
            let item = RawItem(
                id: id,
                title: object["title"]?.string,
                parentID: object["parentID"]?.string,
                childrenIDs: (object["childrenIds"]?.array ?? []).compactMap(\.string),
                kind: kind,
                payload: data[kind] ?? .null)
            items[id] = item
            itemOrder.append(id)
            if let parent = item.parentID { childrenByParent[parent, default: []].append(id) }
        }
    }

    mutating func readSpaces(_ json: ArcJSON?) {
        guard let json else { return }
        guard let (pairs, droppedTail) = json.keyValuePairs() else {
            skip(.malformedEntry, label: "spaces")
            return
        }
        if droppedTail { skip(.malformedEntry, label: "spaces: odd number of elements") }
        for (key, value) in pairs {
            guard let id = key.string, value.object != nil else {
                skip(.malformedEntry, label: "space")
                continue
            }
            if let declared = value["id"]?.string, declared != id {
                skip(.idMismatch, itemID: id)
                continue
            }
            rawSpaces.append(RawSpace(id: id, json: value))
        }
    }

    mutating func readTopApps(_ object: [String: ArcJSON]) {
        if let json = object["topAppsContainerIDs"] {
            if let (pairs, droppedTail) = json.keyValuePairs() {
                if droppedTail { skip(.malformedEntry, label: "topAppsContainerIDs: odd number of elements") }
                for (key, value) in pairs {
                    if let id = value.string {
                        topApps.append((Self.profile(from: key), id))
                    } else {
                        skip(.malformedEntry, label: "favorites container")
                    }
                }
            } else {
                skip(.malformedEntry, label: "topAppsContainerIDs")
            }
        }
        if let legacy = object["topAppsContainerID"]?.string {
            topApps.append((.default, legacy))
        }
    }

    // MARK: Mapping

    mutating func finish() -> ArcImportResult {
        var spaces: [ArcImportSpace] = []
        for raw in rawSpaces {
            spaces.append(mapSpace(raw))
        }

        var favorites: [ArcImportFavorites] = []
        for (profile, containerID) in topApps {
            let nodes = walkRoot(containerID)
            if let index = favorites.firstIndex(where: { $0.profile == profile }) {
                favorites[index].items += nodes
            } else {
                favorites.append(ArcImportFavorites(profile: profile, items: nodes))
            }
        }

        let recovered = handleOrphans()
        for id in itemOrder where !visited.contains(id) {
            guard let item = items[id], ["tab", "list", "splitView"].contains(item.kind) else { continue }
            skip(.unreachable, itemID: id, label: item.title)
        }

        let report = makeReport(spaces: spaces, favorites: favorites, recovered: recovered)
        return ArcImportResult(spaces: spaces, favorites: favorites, recovered: recovered, report: report)
    }

    mutating func mapSpace(_ raw: RawSpace) -> ArcImportSpace {
        var pinned: [ArcImportNode] = []
        var unpinned: [ArcImportNode] = []
        if let (pairs, droppedTail) = raw.json["containerIDs"]?.keyValuePairs() {
            if droppedTail { skip(.malformedEntry, itemID: raw.id, label: "containerIDs: odd number of elements") }
            for (key, value) in pairs {
                guard let containerID = value.string else {
                    skip(.malformedEntry, itemID: raw.id, label: "container id")
                    continue
                }
                switch key.caseName {
                case "pinned": pinned += walkRoot(containerID)
                case "unpinned": unpinned += walkRoot(containerID)
                default: break
                }
            }
        }
        let customInfo = raw.json["customInfo"]
        return ArcImportSpace(
            id: raw.id,
            title: raw.json["title"]?.string ?? "Untitled Space",
            icon: Self.icon(from: customInfo),
            theme: Self.theme(from: customInfo?["windowTheme"]),
            profile: raw.json["profile"].map(Self.profile(from:)) ?? .default,
            pinned: pinned,
            unpinned: unpinned)
    }

    /// Walks a section root (a Space's pinned or unpinned container, or a Favorites container).
    mutating func walkRoot(_ id: String) -> [ArcImportNode] {
        guard items[id] != nil else {
            skip(.missingItem, itemID: id)
            return []
        }
        guard visited.insert(id).inserted else {
            skip(.duplicateReference, itemID: id)
            return []
        }
        return walkChildren(of: id, depth: 0)
    }

    /// Children come from the parent's ordered `childrenIds`, then from items that point back at
    /// the parent through `parentID` without being listed. An item listed under one parent but
    /// pointing at another belongs to the one it points at.
    mutating func walkChildren(of parentID: String, depth: Int) -> [ArcImportNode] {
        let listed = items[parentID]?.childrenIDs ?? []
        let listedSet = Set(listed)
        let unlisted = (childrenByParent[parentID] ?? []).filter { !listedSet.contains($0) }
        var nodes: [ArcImportNode] = []
        for id in listed + unlisted {
            guard let item = items[id] else {
                skip(.missingItem, itemID: id)
                continue
            }
            if let owner = item.parentID, owner != parentID, items[owner] != nil { continue }
            guard visited.insert(id).inserted else {
                skip(.duplicateReference, itemID: id, label: item.title)
                continue
            }
            nodes += map(item, depth: depth)
        }
        return nodes
    }

    mutating func map(_ item: RawItem, depth: Int) -> [ArcImportNode] {
        switch item.kind {
        case "tab":
            if let tab = makeTab(item) { return [.tab(tab)] }
            skip(.tabWithoutURL, itemID: item.id, label: item.title)
            return []
        case "list":
            if let live = item.payload["automaticLiveFolderData"], live != .null {
                skip(.liveFolder, itemID: item.id, label: item.title)
                markSubtreeVisited(item.id)
                return []
            }
            guard depth < Self.maxFolderDepth else {
                skip(.nestedTooDeep, itemID: item.id, label: item.title)
                markSubtreeVisited(item.id)
                return []
            }
            let children = walkChildren(of: item.id, depth: depth + 1)
            return [
                .folder(
                    ArcImportFolder(
                        id: item.id,
                        name: Self.nonEmpty(item.title) ?? "Untitled folder",
                        icon: Self.icon(from: item.payload["customInfo"]),
                        children: children))
            ]
        case "splitView":
            return mapSplitView(item, depth: depth)
        case "easel":
            skipSubtree(.easel, item)
            return []
        case "arcDocument":
            skipSubtree(.note, item)
            return []
        case "sharedObject":
            skipSubtree(.sharedObject, item)
            return []
        default:
            skipSubtree(.unsupportedItem, item)
            return []
        }
    }

    /// A split view of two to four tabs. One tab flattens into that plain tab, and tabs past the fourth follow the split
    /// as plain tabs in order, so what the preview shows is what the sidebar store accepts.
    mutating func mapSplitView(_ item: RawItem, depth: Int) -> [ArcImportNode] {
        var panes: [ArcImportTab] = []
        for child in walkChildren(of: item.id, depth: depth) {
            if case .tab(let tab) = child {
                panes.append(tab)
            } else {
                let name = item.title ?? "Split view"
                skip(.unsupportedItem, itemID: item.id, label: "\(name): only tabs fit in a split view")
            }
        }
        guard !panes.isEmpty else {
            skip(.emptySplitView, itemID: item.id, label: item.title)
            return []
        }
        guard panes.count > 1 else {
            skip(.singleTabSplitView, itemID: item.id, label: item.title)
            return [.tab(panes[0])]
        }
        var extras: [ArcImportTab] = []
        if panes.count > SidebarSplit.maximumPanes {
            extras = Array(panes[SidebarSplit.maximumPanes...])
            panes.removeSubrange(SidebarSplit.maximumPanes...)
            skip(.extraSplitViewPanes, itemID: item.id, label: item.title)
        }
        let focusID = item.payload["focusItemID"]?.string
        let factors = (item.payload["itemWidthFactors"]?.array ?? []).compactMap(\.number)
        let split = ArcImportSplitView(
            id: item.id,
            panes: panes,
            orientation: item.payload["layoutOrientation"]?.caseName.flatMap(ArcImportSplitView.Orientation.init),
            widthFactors: extras.isEmpty ? factors : Array(factors.prefix(panes.count)),
            focusedPane: focusID.flatMap { id in panes.firstIndex { $0.id == id } })
        return [.splitView(split)] + extras.map { .tab($0) }
    }

    func makeTab(_ item: RawItem) -> ArcImportTab? {
        let payload = item.payload
        let url = ["savedURL", "url", "url_legacy"].lazy.compactMap { Self.nonEmpty(payload[$0]?.string) }.first
        guard let url else { return nil }
        let savedTitle = Self.nonEmpty(payload["savedTitle"]?.string ?? payload["title_legacy"]?.string)
        let name = Self.nonEmpty(item.title)
        // A title that differs from the saved page title is a name the person typed.
        return ArcImportTab(
            id: item.id,
            url: url,
            savedTitle: savedTitle,
            customName: name == savedTitle ? nil : name)
    }

    mutating func skipSubtree(_ reason: ArcImportSkipped.Reason, _ item: RawItem) {
        skip(reason, itemID: item.id, label: item.title)
        markSubtreeVisited(item.id)
    }

    mutating func markSubtreeVisited(_ id: String) {
        var pending = [id]
        while let next = pending.popLast() {
            visited.insert(next)
            let item = items[next]
            let children = (item?.childrenIDs ?? []) + (childrenByParent[next] ?? [])
            pending += children.filter { !visited.contains($0) && items[$0] != nil }
        }
    }

    // MARK: Orphans

    /// Items that no Space or Favorites root reaches and that have no existing parent, the cases
    /// Arc's own cleanup moves into its "Recently recovered" folder.
    mutating func handleOrphans() -> [ArcImportNode] {
        var recovered: [ArcImportNode] = []
        for id in itemOrder where !visited.contains(id) {
            guard let item = items[id], ["tab", "list", "splitView"].contains(item.kind) else { continue }
            if let parent = item.parentID, items[parent] != nil { continue }
            visited.insert(id)
            switch options.orphans {
            case .collect:
                recovered += map(item, depth: 0)
            case .drop:
                skip(.orphan, itemID: id, label: item.title)
                markSubtreeVisited(id)
            }
        }
        return recovered
    }

    // MARK: Report

    mutating func skip(_ reason: ArcImportSkipped.Reason, itemID: String? = nil, label: String? = nil) {
        skipped.append(ArcImportSkipped(reason: reason, itemID: itemID, label: Self.nonEmpty(label)))
    }

    func makeReport(spaces: [ArcImportSpace], favorites: [ArcImportFavorites], recovered: [ArcImportNode])
        -> ArcImportReport
    {
        var stats = Stats()
        for space in spaces {
            stats.add(space.pinned, depth: 0, into: \.pinnedTabs, countingNames: true)
            stats.add(space.unpinned, depth: 0, into: \.unpinnedTabs)
        }
        for list in favorites { stats.add(list.items, depth: 0, into: \.favorites) }
        var rescued = Stats()
        rescued.add(recovered, depth: 0, into: \.pinnedTabs)
        return ArcImportReport(
            spaces: spaces.count,
            folders: stats.folders,
            emptyFolders: stats.emptyFolders,
            maxFolderDepth: stats.maxDepth,
            pinnedTabs: stats.pinnedTabs,
            unpinnedTabs: stats.unpinnedTabs,
            favorites: stats.favorites,
            splitViews: stats.splitViews,
            customNamedTabs: stats.customNamed,
            recoveredItems: recovered.count,
            recoveredTabs: rescued.pinnedTabs,
            skipped: skipped)
    }

    private struct Stats {
        var folders = 0
        var emptyFolders = 0
        var maxDepth = 0
        var pinnedTabs = 0
        var unpinnedTabs = 0
        var favorites = 0
        var splitViews = 0
        var customNamed = 0

        /// Counts nodes, adding every tab (split view panes included) to the `tabs` counter.
        mutating func add(
            _ nodes: [ArcImportNode], depth: Int, into tabs: WritableKeyPath<Stats, Int>, countingNames: Bool = false
        ) {
            for node in nodes {
                switch node {
                case .tab(let tab):
                    self[keyPath: tabs] += 1
                    if countingNames, tab.customName != nil { customNamed += 1 }
                case .splitView(let split):
                    splitViews += 1
                    self[keyPath: tabs] += split.panes.count
                    if countingNames { customNamed += split.panes.filter { $0.customName != nil }.count }
                case .folder(let folder):
                    folders += 1
                    if folder.children.isEmpty { emptyFolders += 1 }
                    maxDepth = max(maxDepth, depth + 1)
                    add(folder.children, depth: depth + 1, into: tabs, countingNames: countingNames)
                }
            }
        }
    }

    // MARK: Small decoders

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func profile(from json: ArcJSON) -> ArcImportProfile {
        guard json.caseName == "custom" else { return .default }
        if let name = findString("directoryBasename", in: json["custom"] ?? .null), !name.isEmpty {
            return .custom(directoryBasename: name)
        }
        return .default
    }

    static func findString(_ key: String, in json: ArcJSON) -> String? {
        guard let object = json.object else { return nil }
        if let value = object[key]?.string { return value }
        for name in object.keys.sorted() {
            if let found = findString(key, in: object[name] ?? .null) { return found }
        }
        return nil
    }

    static func icon(from customInfo: ArcJSON?) -> ArcImportIcon? {
        guard let iconType = customInfo?["iconType"], let name = iconType.caseName else { return nil }
        let value = iconType[name]
        switch name {
        case "emoji":
            return (value?.scalarText).map(ArcImportIcon.emoji)
        case "emojiInt":
            guard let code = value?.scalarText.flatMap({ UInt32($0) }), let scalar = Unicode.Scalar(code) else {
                return nil
            }
            return .emoji(String(Character(scalar)))
        case "icon", "symbol":
            return (value?.scalarText).map(ArcImportIcon.symbol)
        default:
            return nil
        }
    }

    static func theme(from windowTheme: ArcJSON?) -> ArcImportTheme? {
        guard let windowTheme else { return nil }
        let theme = ArcImportTheme(
            style: windowTheme["background"]?["style"]?.caseName,
            appearance: windowTheme["windowAppearance"]?.caseName)
        return theme.style == nil && theme.appearance == nil ? nil : theme
    }
}
