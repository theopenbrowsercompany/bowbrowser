import AppKit
import BowCore

/// The panes side by side while a window's page area shows more than one: a split view with thin dividers the person
/// can drag, each pane keeping at least `SidebarSplit.minimumPaneFraction` of the width, and the focused pane outlined
/// in the system accent color. Each pane keeps its share of the width when the window resizes or goes full screen.
/// The window core (`BrowserWindowController`) decides what shows; this view only places it.
final class PaneContainer: NSSplitView, NSSplitViewDelegate {
    /// Called with each pane's share of the width after the person dragged a divider.
    var onDividerDrag: (([Double]) -> Void)?
    /// Each pane's share of the width, in pane order.
    private var fractions: [Double] = []
    /// The pane drawn with the focus outline.
    private var focusedIndex = 0
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

    /// Shows `panes` in order, each taking its share of `fractions`, with the pane at `focusedIndex` outlined. Views
    /// that leave lose their outline; an empty list empties the container.
    func show(_ panes: [NSView], fractions: [Double], focusedIndex: Int) {
        for view in subviews where !panes.contains(where: { $0 === view }) {
            view.layer?.borderWidth = 0
            view.removeFromSuperview()
        }
        if !subviews.elementsEqual(panes, by: ===) {
            for view in panes { addSubview(view) }
        }
        self.fractions = fractions
        self.focusedIndex = focusedIndex
        placePanes()
        drawOutline()
    }

    /// The width the panes share, without the dividers.
    private var paneWidth: CGFloat {
        max(bounds.width - dividerThickness * CGFloat(max(subviews.count - 1, 0)), 1)
    }

    /// Sets each pane's frame from `fractions`, the last pane taking what rounding leaves.
    private func placePanes() {
        guard fractions.count == subviews.count, !subviews.isEmpty else { return }
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let last = index == subviews.count - 1
            let width = last ? max(bounds.width - x, 0) : (paneWidth * CGFloat(fractions[index])).rounded()
            view.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + dividerThickness
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

    /// Keeps each pane's share when the split view resizes with the window.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if fractions.count == subviews.count {
            placePanes()
        } else {
            adjustSubviews()
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // AppKit names the divider only when the person dragged it, not when the split view resized.
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        fractions = subviews.map { Double($0.frame.width / paneWidth) }
        onDividerDrag?(fractions)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, subviews[dividerIndex].frame.minX + minimumPane)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, subviews[dividerIndex + 1].frame.maxX - minimumPane - dividerThickness)
    }

    private var minimumPane: CGFloat { paneWidth * CGFloat(SidebarSplit.minimumPaneFraction) }
}
