import Foundation

/// When the panes' shares are reported for saving while the person moves a divider between panes: once, when they
/// let go, with the shares the panes ended at, never on every step of the drag. A divider that moves outside a drag
/// (the keyboard or an accessibility client sets it) reports at once, since no release will follow. A drag that moved
/// nothing reports nothing.
public struct PaneDividerDrag: Equatable, Sendable {
    /// True between the press on a divider and its release.
    public private(set) var isDragging = false
    /// The shares the drag has reached so far, nil until it moved.
    private var pending: [Double]?

    public init() {}

    /// The person pressed on a divider.
    public mutating func began() {
        isDragging = true
        pending = nil
    }

    /// A divider moved and the panes now hold `fractions`. Returns the shares to report now: nil during a drag (they
    /// wait for the release), `fractions` outside one.
    public mutating func moved(_ fractions: [Double]) -> [Double]? {
        guard isDragging else { return fractions }
        pending = fractions
        return nil
    }

    /// The person let go of the divider. Returns the shares the drag ended at, nil when it moved nothing or no drag
    /// was under way.
    public mutating func ended() -> [Double]? {
        defer {
            isDragging = false
            pending = nil
        }
        return isDragging ? pending : nil
    }
}
