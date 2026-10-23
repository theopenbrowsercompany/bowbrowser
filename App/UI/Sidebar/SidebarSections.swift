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

    /// The height of the header row for `content`, for a header that grows or shrinks with it (a Favorites grid
    /// gaining a row of icons). Asked on every `SidebarView.show(_:)`; a change resizes the row. Defaults to
    /// `headerHeight`.
    func headerHeight(for content: SidebarContent) -> CGFloat

    /// The view drawn in the section's header row, or nil to leave it empty. The outline asks once per window and
    /// keeps the view (or the lack of one) for the section's row.
    func makeHeaderView() -> NSView?

    /// Brings `view`, the one `makeHeaderView()` made, up to date with `content`: once on every `SidebarView.show(_:)`,
    /// and when the view is made outside one, so a header such as a Space switcher always shows the Space on screen.
    /// `context` is nil while the sidebar has no window to act on.
    ///
    /// Only update the view here. Acting on `context` changes what the sidebar shows while it is showing: such a
    /// change is shown on the next run loop turn, not within this call, so act from the view's own controls instead.
    func updateHeaderView(_ view: NSView, content: SidebarContent, context: (any SidebarActionContext)?)
}

extension SidebarSection {
    var headerHeight: CGFloat { 4 }
    func headerHeight(for content: SidebarContent) -> CGFloat { headerHeight }
    func makeHeaderView() -> NSView? { nil }
    func updateHeaderView(_ view: NSView, content: SidebarContent, context: (any SidebarActionContext)?) {}
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
        // A short Line colored rule, inset from both sides.
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = BowBrand.line
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BowBrand.sidebarLeading + 10),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -(BowBrand.sidebarTrailing + 10)),
            line.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
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
