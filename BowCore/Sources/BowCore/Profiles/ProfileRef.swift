import Foundation

/// One browser profile as the registry knows it: the storage (cookies, logins, history) that Spaces point at.
public struct ProfileRecord: Hashable, Sendable {
    /// What a Space stores in `SidebarSpace.profileID`. For every profile but the default it is also the engine's
    /// profile ID and the folder name, so it only ever holds `[A-Za-z0-9._-]` and never differs from another ID
    /// only in case.
    public var id: SidebarProfileID
    /// The name the person sees. Renaming changes only this.
    public var name: String
    /// Persistent profiles keep their data in a folder; ephemeral ones live in memory and lose it on quit.
    public var isPersistent: Bool

    public init(id: SidebarProfileID, name: String, isPersistent: Bool) {
        self.id = id
        self.name = name
        self.isPersistent = isPersistent
    }

    public var isDefault: Bool { id == .default }

    /// The engine's profile ID: `Default` for the default profile, otherwise the same text as `id`.
    public var engineID: ProfileID { isDefault ? .default : ProfileID(id.rawValue) }

    /// What the app hands the engine to create this profile's storage.
    public var ref: ProfileRef { isPersistent ? .persistent(engineID) : .ephemeral(engineID) }

    /// The folder name of a persistent profile inside the root data folder: `Default` or `Profile-<id>`. The engine
    /// uses exactly this, one level under the root, because a deeper cache path silently falls back to memory.
    public var folderName: String? { isPersistent ? ProfileRegistry.folderName(for: engineID) : nil }

    /// The cache path to give the engine for this profile, or nil for an ephemeral one.
    public func cachePath(inRoot root: URL) -> URL? {
        folderName.map { root.appendingPathComponent($0, isDirectory: true) }
    }
}

/// How the engine should create a profile: with a folder on disk, or in memory only.
public enum ProfileRef: Hashable, Sendable {
    case persistent(ProfileID)
    case ephemeral(ProfileID)

    public var engineID: ProfileID {
        switch self {
        case .persistent(let id), .ephemeral(let id): return id
        }
    }

    public var isPersistent: Bool {
        if case .persistent = self { return true }
        return false
    }
}

/// What moving a tab from one Space to another means for its page.
public enum TabMoveKind: Equatable, Sendable {
    /// Both Spaces show the same profile: the tab keeps its live page and its logins.
    case keepsLivePage
    /// The Spaces show different profiles: the page cannot move between them. The app asks first, then loads the
    /// tab's address again in the target profile.
    case needsReload(from: SidebarProfileID, to: SidebarProfileID)

    public static func between(_ source: SidebarProfileID, _ target: SidebarProfileID) -> TabMoveKind {
        source == target ? .keepsLivePage : .needsReload(from: source, to: target)
    }
}

extension SidebarGraph {
    /// What moving a tab from the Space `source` to the Space `target` means, or nil when either Space is unknown.
    /// Moving within one Space, or between Spaces on one profile, keeps the live page.
    public func tabMoveKind(from source: SidebarSpaceID, to target: SidebarSpaceID) -> TabMoveKind? {
        guard let from = space(source), let to = space(target) else { return nil }
        return .between(from.profileID, to.profileID)
    }
}
