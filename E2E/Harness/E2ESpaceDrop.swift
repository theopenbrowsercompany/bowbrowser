import Foundation

/// How a drag held over a Space's footer icon ended.
enum E2ESpaceDropEnd: String {
    /// Released over the icon (`performDragOperation`).
    case drop
    /// Moved away without a drop (`draggingExited`).
    case leave
}

/// What happened to a drag over a Space's footer icon (`E2ESpaceDropApp.dragOnSpaceIcon`).
struct E2ESpaceDropResult: Equatable, CustomStringConvertible {
    /// What `draggingEntered` answered: "move" or "none".
    var operation: String
    /// Whether the icon showed its ring while the drag was over it.
    var ringedOver: Bool
    /// Whether the icon showed its ring after the drag ended.
    var ringedAfter: Bool
    /// What `performDragOperation` answered (false when the drag only left).
    var performed: Bool

    var description: String {
        "operation=\(operation) ringed_over=\(ringedOver) ringed_after=\(ringedAfter) performed=\(performed)"
    }
}

/// Dragging a sidebar item over a Space's icon in the footer switcher, as a test drives it: the icon's own
/// `NSDraggingDestination` methods get a real pasteboard item made the way the sidebar makes it, and a dragging
/// source in the window's sidebar. E2E/Harness/E2EAppAdapter+SpaceDrop.swift implements it.
@MainActor
protocol E2ESpaceDropApp: E2EProfilesApp, E2EStoreSeedApp {
    /// Drags sidebar item `item` (an ID from `E2ESeededWindow.itemIDs`, or a Favorite's) over the footer icon of the
    /// Space titled `space` in the window `page` is in, then ends the drag as `end` says. Throws when the window has
    /// no such icon or the item has no row or Favorites tile to drag.
    func dragOnSpaceIcon(item: String, space: String, end: E2ESpaceDropEnd, in page: any E2EPage) throws
        -> E2ESpaceDropResult
}
