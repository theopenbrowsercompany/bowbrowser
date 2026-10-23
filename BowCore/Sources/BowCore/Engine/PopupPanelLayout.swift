import CoreGraphics
import Foundation

// Where a popup panel goes and how large it is: a pure function, so the window applies the result and the rules
// stay easy to change and test.

/// The size and place of a popup panel, the small window attached to the opener's window that shows a sign in popup.
public enum PopupPanelLayout {
    /// The page area when the page asked for no size (an identity provider page opened without one).
    public static let defaultSize = CGSize(width: 500, height: 640)
    /// The smallest page area, so a tiny request still shows a usable sign in form.
    public static let minimumSize = CGSize(width: 320, height: 240)
    /// The room left between the panel and each edge of the opener's window, when the window is large enough.
    public static let margin: CGFloat = 20

    /// The page area of the panel: the width and height `window.open` asked for (each falls back to `defaultSize`
    /// when not set), no smaller than `minimumSize` and no larger than `available` (the opener window's size) less
    /// `margin` on each side. `minimumSize` wins over a window smaller than it.
    public static func contentSize(for request: PopupRequest, within available: CGSize) -> CGSize {
        let width = request.windowFeatures.width ?? request.requestedSize?.width
        let height = request.windowFeatures.height ?? request.requestedSize?.height
        let wanted = CGSize(
            width: width.map { CGFloat($0) } ?? defaultSize.width,
            height: height.map { CGFloat($0) } ?? defaultSize.height)
        let maximum = CGSize(width: available.width - 2 * margin, height: available.height - 2 * margin)
        return CGSize(
            width: max(min(wanted.width, maximum.width), minimumSize.width),
            height: max(min(wanted.height, maximum.height), minimumSize.height))
    }

    /// The panel's frame: `size` (the panel window's whole frame) centered over `parent`, the opener window's frame,
    /// on whole points. The position the page asked for is ignored, so the panel always sits over its window.
    public static func frame(size: CGSize, centeredIn parent: CGRect) -> CGRect {
        CGRect(
            x: (parent.midX - size.width / 2).rounded(),
            y: (parent.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height)
    }
}
