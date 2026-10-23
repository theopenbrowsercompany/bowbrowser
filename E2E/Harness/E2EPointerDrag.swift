import Foundation

/// Where a pointer drag in the sidebar is let go (`E2EPointerDragApp.pointerDragSidebarRow(_:to:in:)`).
enum E2EPointerTarget: CustomStringConvertible {
    /// Inside the sidebar row titled `title` (the first one with that title), `fraction` of the way down its
    /// height: 0 is its top edge and 1 its bottom edge.
    case row(String, fraction: Double)
    /// The middle of the web page beside the sidebar, outside the sidebar.
    case page

    var description: String {
        switch self {
        case .row(let title, let fraction): "row \(title) at \(fraction)"
        case .page: "the page"
        }
    }
}

/// What a pointer drag did: the view under the pointer where it was let go, and whether that view took the drop.
struct E2EPointerDrop: CustomStringConvertible {
    /// The class of the drop destination under the release point, nil when no view there takes sidebar drags.
    var destination: String?
    /// Whether the destination accepted the drop.
    var accepted: Bool

    var description: String { "\(destination ?? "no destination") accepted=\(accepted)" }
}

/// Dragging a sidebar row by pointer position, as a person drags it: the drag starts at the row's center, moves to
/// a point in the window, and is let go there. The sidebar is AppKit, which DevTools input cannot reach, and a real
/// drag session would follow the real mouse, so the adapter hands the window's views the drag (entered, updated,
/// then performed or exited) at those window points; the outline resolves the point to a drop position itself.
@MainActor
protocol E2EPointerDragApp: E2EZonesApp {
    /// Drags the first sidebar row titled `title` from its center to `target` and lets it go there. Throws when no
    /// row has that title or the row cannot be dragged.
    func pointerDragSidebarRow(_ title: String, to target: E2EPointerTarget, in page: any E2EPage) throws
        -> E2EPointerDrop
}
