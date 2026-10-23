import Foundation

// Air Traffic Control's decisions around the routing table: where a routed link opens in the app, which Space takes a
// link routed to a profile, which destinations still exist, and how the editor names the app the last link came from.

/// Where a link from another app opens, once the routing table has decided.
public enum LinkRouting {
    /// Where the app opens a routed link.
    public enum Opening: Equatable, Sendable {
        /// A new tab in this Space, created there so its first request goes out in the Space's profile.
        case space(SidebarSpaceID)
        /// A new tab in a Space of this profile (`spaceID(forProfile:in:)` picks which), created there.
        case profile(SidebarProfileID)
        /// A new Little Arc window.
        case littleArc
        /// A new tab in the Space on screen of the most recently used browser window (a new window when none is
        /// open), as links opened before routing existed.
        case browserWindow
    }

    /// Where the app opens `decision`'s link. A rule (or the "no source" fallback) naming Little Arc opens it there
    /// whatever the Little Arc setting says, because the person asked for it in that rule. The default naming Little
    /// Arc follows the setting (`setting` is nil when never set), as Arc does without rules: Little Arc while it is on,
    /// else the browser window. Little Arc needs a Space for its page's profile (`hasSpace`: a browser window's Space
    /// on screen, or the Space shown last when no window is open), so with none the link opens in a browser window.
    public static func opening(for decision: RoutingDecision, littleArcSetting setting: Bool?, hasSpace: Bool)
        -> Opening
    {
        switch decision.destination {
        case .space(let id): return .space(SidebarSpaceID(id))
        case .profile(let id): return .profile(SidebarProfileID(id))
        case .mostRecentWindow: return .browserWindow
        case .littleArc:
            let open: Bool
            if case .defaultDestination = decision.basis {
                open = LittleArc.opening(setting: setting, hasSpace: hasSpace) == .littleArc
            } else {
                open = hasSpace
            }
            return open ? .littleArc : .browserWindow
        }
    }

    /// The Space a link routed to `profile` opens in within `graph`: the Space on screen when it shows that profile,
    /// else the first Space of that profile in sidebar order, else none. Profile IDs match ignoring case, as the
    /// engine matches profile folders.
    public static func spaceID(forProfile profile: SidebarProfileID, in graph: SidebarGraph) -> SidebarSpaceID? {
        let key = profile.rawValue.lowercased()
        let spaces = graph.spaces.filter { $0.profileID.rawValue.lowercased() == key }
        if let active = graph.activeSpaceID, spaces.contains(where: { $0.id == active }) { return active }
        return spaces.first?.id
    }

    /// Whether `destination` exists given the Spaces and profiles the app knows: a Space by ID, a profile when the
    /// registry lists it or a Space shows it (IDs ignoring case). Little Arc and the most recent window always exist.
    public static func isAvailable(
        _ destination: RouteDestination, spaceIDs: Set<String>, profileIDs: Set<String>
    ) -> Bool {
        switch destination {
        case .space(let id): return spaceIDs.contains(id)
        case .profile(let id):
            let key = id.lowercased()
            return profileIDs.contains { $0.lowercased() == key }
        case .littleArc, .mostRecentWindow: return true
        }
    }

    /// The editor's line about the last link from another app: nil `arrived` means no link has arrived since Bow
    /// started; otherwise the app's name and bundle identifier, the bundle identifier alone when the app has no name,
    /// or "no source app" when the sender could not be named.
    public static func lastSourceLine(arrived: LastSource?) -> String {
        guard let arrived else { return "No link from another app has arrived since Bow started." }
        guard let bundleID = arrived.bundleID, !bundleID.isEmpty else {
            return "Last link came from: no source app (the sender could not be identified)"
        }
        if let name = arrived.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "Last link came from: \(name) (\(bundleID))"
        }
        return "Last link came from: \(bundleID)"
    }

    /// The app the last link came from, as the editor shows it.
    public struct LastSource: Equatable, Sendable {
        /// The app's bundle identifier after a helper process was mapped to its parent app, nil for no source.
        public var bundleID: String?
        /// The app's name, when known.
        public var name: String?

        public init(bundleID: String?, name: String?) {
            self.bundleID = bundleID
            self.name = name
        }
    }
}
