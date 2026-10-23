import AppKit
import BowCore

/// One section of the sidebar outline, top to bottom as `SidebarSections.all` lists them: the Favorites area, the
/// pinned tabs, the divider and today's tabs.
///
/// Each section is one row at the top level of the outline (its header, which may be only a thin spacer) with the
/// items of its container below it. A section without a container (the divider) has a header and no items. The
/// outline keeps every section expanded and never shows a disclosure triangle for it.
///
/// Extension point: a new section (or a section that replaces one, such as the Favorites grid) is one new file with
/// a type conforming to this protocol plus one line in `SidebarSections.all` (`SidebarSectionList.swift`).
@MainActor
protocol SidebarSection {
    init()

    /// The zone the section's items are in, or nil for a section that holds no items (the divider).
    var zone: SidebarZone? { get }

    /// The container whose items the section lists, in the Space on screen. Nil lists none.
    func containerID(in graph: SidebarGraph, space: SidebarSpace) -> SidebarItemID?

    /// The height of the section's header row (at least 1 point, as the outline needs a visible row).
    var headerHeight: CGFloat { get }

    /// The view drawn in the section's header row, or nil to leave it empty.
    func makeHeaderView() -> NSView?
}

extension SidebarSection {
    var headerHeight: CGFloat { 4 }
    func makeHeaderView() -> NSView? { nil }
}

/// The three zones of a Space's sidebar. Arc's model: Favorites are shared by the profile's Spaces, pinned tabs are
/// kept, and today's tabs are where new tabs open and the only ones ever archived.
enum SidebarZone: String, Sendable {
    case favorites
    case pinned
    case today
}

/// The pinned tabs of the Space on screen, with their folders as expandable rows.
struct PinnedSection: SidebarSection {
    var zone: SidebarZone? { .pinned }

    func containerID(in graph: SidebarGraph, space: SidebarSpace) -> SidebarItemID? {
        space.pinnedContainerID
    }
}

/// The line between the pinned tabs and today's tabs. It is always shown, also when either side is empty, so there
/// is always somewhere to drop a tab to pin or unpin it.
struct DividerSection: SidebarSection {
    var zone: SidebarZone? { nil }
    var headerHeight: CGFloat { 13 }

    func containerID(in graph: SidebarGraph, space: SidebarSpace) -> SidebarItemID? { nil }

    func makeHeaderView() -> NSView? {
        let view = NSView()
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("Divider between pinned tabs and today's tabs")
        return view
    }
}

/// Today's tabs of the Space on screen: where new tabs open, and the only tabs archiving ever takes.
struct TodaySection: SidebarSection {
    var zone: SidebarZone? { .today }

    func containerID(in graph: SidebarGraph, space: SidebarSpace) -> SidebarItemID? {
        space.unpinnedContainerID
    }
}
