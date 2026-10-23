import AppKit
import BowCore

/// The panes while a window's page area shows more than one: a split view, side by side or stacked top to bottom, with
/// thin dividers the person can drag, each pane keeping at least `SidebarSplit.minimumPaneFraction` of the length,
/// and the focused pane outlined in the system accent color. Each pane keeps its share when the window resizes or
/// goes full screen. The window core (`BrowserWindowController`) decides what shows; this view only places it.
final class PaneContainer: NSSplitView, NSSplitViewDelegate {
    /// Called with each pane's share on every step of a divider drag, so the window keeps its layout in step.
    var onDividerMove: (([Double]) -> Void)?
    /// Called once the person let go of a divider (or a divider moved outside a drag), with each pane's share then:
    /// the moment the shares are saved (`PaneDividerDrag` decides).
    var onDividerDragEnd: (([Double]) -> Void)?
    /// Each pane's share of the length, in pane order.
    private var fractions: [Double] = []
    /// The pane drawn with the focus outline.
    private var focusedIndex = 0
    private var drag = PaneDividerDrag()
    /// The focus outline's width, also drawn by a view a feature puts over the focused pane (the certificate page).
    static let outlineWidth: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        // The accent color can change while the panes show.
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `panes` in order, each taking its share of `fractions`, laid out as `orientation` (side by side or
    /// stacked), with the pane at `focusedIndex` outlined. Views that leave lose their outline; an empty list empties
    /// the container.
    func show(
        _ panes: [NSView], fractions: [Double], focusedIndex: Int, orientation: SidebarSplit.Orientation = .horizontal
    ) {
        for view in subviews where !panes.contains(where: { $0 === view }) {
            view.layer?.borderWidth = 0
            view.removeFromSuperview()
        }
        if !subviews.elementsEqual(panes, by: ===) {
            for view in panes { addSubview(view) }
        }
        // NSSplitView's vertical dividers put the panes side by side; horizontal ones stack them.
        isVertical = orientation == .horizontal
        self.fractions = fractions
        self.focusedIndex = focusedIndex
        placePanes()
        drawOutline()
    }

    /// The length along the layout: the width side by side, the height stacked.
    private func length(of size: NSSize) -> CGFloat { isVertical ? size.width : size.height }

    /// The length the panes share, without the dividers.
    private var paneLength: CGFloat {
        max(length(of: bounds.size) - dividerThickness * CGFloat(max(subviews.count - 1, 0)), 1)
    }

    /// Sets each pane's frame from `fractions`, the last pane taking what rounding leaves. Stacked panes go top to
    /// bottom (a split view is flipped).
    private func placePanes() {
        guard fractions.count == subviews.count, !subviews.isEmpty else { return }
        let total = length(of: bounds.size)
        var offset: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let last = index == subviews.count - 1
            let size = last ? max(total - offset, 0) : (paneLength * CGFloat(fractions[index])).rounded()
            view.frame =
                isVertical
                ? NSRect(x: offset, y: 0, width: size, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: size)
            offset += size + dividerThickness
        }
        needsDisplay = true
    }

    private func drawOutline() {
        for (index, view) in subviews.enumerated() {
            view.wantsLayer = true
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            view.layer?.borderWidth = index == focusedIndex ? Self.outlineWidth : 0
        }
    }

    @objc private func systemColorsChanged() {
        drawOutline()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawOutline()
    }

    // MARK: Dragging a divider

    /// A press on a divider: NSSplitView tracks the drag inside `super.mouseDown` and returns once the person lets go,
    /// so the drag ends right after it.
    override func mouseDown(with event: NSEvent) {
        dividerDragBegan()
        super.mouseDown(with: event)
        dividerDragEnded()
    }

    /// The person pressed on a divider; its moves wait for the release before they are saved.
    func dividerDragBegan() {
        drag.began()
    }

    /// The person let go of the divider: the shares it ended at are reported once.
    func dividerDragEnded() {
        if let ended = drag.ended() { onDividerDragEnd?(ended) }
    }

    /// Keeps each pane's share when the split view resizes with the window.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if fractions.count == subviews.count {
            placePanes()
        } else {
            adjustSubviews()
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // AppKit names the divider only when it moved, not when the split view resized.
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        fractions = subviews.map { Double(length(of: $0.frame.size) / paneLength) }
        onDividerMove?(fractions)
        if let now = drag.moved(fractions) { onDividerDragEnd?(now) }
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let start = isVertical ? subviews[dividerIndex].frame.minX : subviews[dividerIndex].frame.minY
        return max(proposedMinimumPosition, start + minimumPane)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let next = subviews[dividerIndex + 1].frame
        let end = isVertical ? next.maxX : next.maxY
        return min(proposedMaximumPosition, end - minimumPane - dividerThickness)
    }

    private var minimumPane: CGFloat { paneLength * CGFloat(SidebarSplit.minimumPaneFraction) }
}
