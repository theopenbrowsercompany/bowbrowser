import AppKit
import BowCore

/// Where a sidebar accessory sits: above the outline (under the New Tab button) or in the footer along the bottom
/// edge. Each slot lists its accessories in `SidebarAccessories.all` order, and an empty slot takes no room.
enum SidebarAccessoryPlacement: Sendable {
    case top
    case footer
}

/// A control the sidebar shows above or below its outline, such as the Space switcher or the archive button.
///
/// Extension point: a new accessory is one new file with a class conforming to this protocol plus one line in
/// `SidebarAccessories.all` (`SidebarAccessoryList.swift`). Each window's sidebar makes its own instance.
@MainActor
protocol SidebarAccessory: AnyObject {
    init()

    /// The slot the accessory sits in.
    static var placement: SidebarAccessoryPlacement { get }

    /// The accessory's view, added once to its slot. It sizes itself (its height in a slot is its fitting height).
    var view: NSView { get }

    /// Brings the accessory up to date with `content`: called on every `SidebarView.show(_:)`. `context` is nil while
    /// the sidebar has no window to act on.
    func update(content: SidebarContent, context: (any SidebarActionContext)?)
}

/// A view at the trailing end of a tab's row, before its close button, such as "Back to pinned URL".
///
/// Extension point: a new provider is one new file with a type conforming to this protocol plus one line in
/// `SidebarRowAccessories.all` (`SidebarAccessoryList.swift`). A row shows the view of the first provider, in list
/// order, that gives one.
@MainActor
protocol SidebarRowAccessory {
    /// The view for the row of tab `item`, or nil for none. Asked each time the row is drawn and on every
    /// `SidebarView.show(_:)` while it is on screen, with `reusing` set to the accessory the row view held last, to
    /// update and return rather than make anew when it is this provider's kind of view (a reused row view may have
    /// shown another tab, or another provider's view).
    static func accessoryView(
        for item: SidebarItemID, reusing view: NSView?, content: SidebarContent,
        context: (any SidebarActionContext)?
    ) -> NSView?
}

/// A horizontal two-finger swipe on the sidebar, as its handler sees it.
struct SidebarSwipe: Equatable, Sendable {
    enum Phase: Sendable {
        /// The movement became a swipe; `translation` holds the movement so far.
        case began
        case changed
        /// The fingers lifted.
        case ended
        /// The system cancelled the gesture.
        case cancelled
    }

    var phase: Phase
    /// The horizontal distance moved since the swipe began, in points, positive when the fingers move right
    /// (the sign of `NSEvent.scrollingDeltaX`, which follows the person's scroll direction setting).
    var translation: CGFloat
}

/// What the sidebar gives a horizontal two-finger swipe to, such as the Spaces feature swiping between Spaces.
///
/// Extension point: set `SidebarView.swipeHandler`. Without a handler, every scroll goes to the outline as before.
/// With one, a trackpad scroll whose first few points of movement are mostly sideways (more than twice as far as
/// vertically) is the handler's from then until the fingers lift, momentum included, and its `translation` counts
/// those first points too; any other scroll still goes to the outline.
@MainActor
protocol SidebarSwipeHandler: AnyObject {
    func sidebarSwipe(_ swipe: SidebarSwipe)
}

/// The side the outline's old content leaves to in `SidebarView.slideOutline(_:change:)`; the new content comes
/// in from the other side. `.left` suits going to the next Space, `.right` the previous one.
enum SidebarSlideDirection: Sendable {
    case left
    case right
}

/// The outline's scroll view, which hands sideways trackpad swipes to the sidebar's swipe handler.
@MainActor
final class SidebarScrollView: NSScrollView {
    weak var swipeHandler: (any SidebarSwipeHandler)?

    /// How far the fingers move (in points) before a gesture is taken as a swipe or a scroll.
    private static let decisionDistance: CGFloat = 6
    /// How many times more sideways than vertical the movement must be to make a swipe.
    private static let swipeRatio: CGFloat = 2

    private enum Tracking {
        /// No gesture, or one that belongs to the outline.
        case none
        /// The fingers touched and have moved this far; the outline scrolls meanwhile, until the movement shows who
        /// the gesture belongs to.
        case undecided(dx: CGFloat, dy: CGFloat)
        case outline
        /// The handler's, with the horizontal distance moved so far.
        case swipe(CGFloat)
        /// The handler's gesture ended; its momentum events are swallowed.
        case momentum
    }

    private var tracking = Tracking.none

    override func scrollWheel(with event: NSEvent) {
        guard let handler = swipeHandler, event.hasPreciseScrollingDeltas else {
            tracking = .none
            super.scrollWheel(with: event)
            return
        }
        if !event.momentumPhase.isEmpty {
            if case .momentum = tracking {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { tracking = .none }
                return
            }
            super.scrollWheel(with: event)
            return
        }
        let ends = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            tracking = .undecided(dx: 0, dy: 0)
        }
        switch tracking {
        case .undecided(let dx, let dy):
            let x = dx + event.scrollingDeltaX
            let y = dy + event.scrollingDeltaY
            if ends {
                tracking = .none
            } else if hypot(x, y) < Self.decisionDistance {
                tracking = .undecided(dx: x, dy: y)
            } else if abs(x) > Self.swipeRatio * abs(y) {
                tracking = .swipe(x)
                handler.sidebarSwipe(SidebarSwipe(phase: .began, translation: x))
                return
            } else {
                tracking = .outline
            }
            super.scrollWheel(with: event)
        case .swipe(let moved):
            let total = moved + event.scrollingDeltaX
            if ends {
                tracking = .momentum
                let phase: SidebarSwipe.Phase = event.phase.contains(.ended) ? .ended : .cancelled
                handler.sidebarSwipe(SidebarSwipe(phase: phase, translation: total))
                // The outline saw the gesture begin while it was undecided; let it end its own scroll.
                super.scrollWheel(with: event)
            } else {
                tracking = .swipe(total)
                handler.sidebarSwipe(SidebarSwipe(phase: .changed, translation: total))
            }
        case .none, .outline, .momentum:
            if ends { tracking = .none }
            super.scrollWheel(with: event)
        }
    }
}

/// The picture of the outline's old content while `SidebarView.slideOutline(_:change:)` slides it out. It takes no
/// clicks or drags, so they reach the new content beneath it during the slide.
@MainActor
final class SidebarSlideSnapshot: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
