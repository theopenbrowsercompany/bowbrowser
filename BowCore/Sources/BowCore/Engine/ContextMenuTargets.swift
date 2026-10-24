import Foundation

// What a right click hit, for an engine that gives no hit test of its own. The engine's own menu says which kinds of
// target the click hit (it offered link items, image items, editing items), and a page script reports the URLs and
// text, from each frame that saw the click, on its own schedule. `ContextMenuTargets.request` merges the two into one
// `ContextMenuRequest`, so the engine layer only translates its menu items and the script's messages into these values.

/// What the engine put in its own menu for this click, by kind.
public struct ContextMenuHints: Equatable, Sendable {
    /// The menu offered items for a link (open or copy the link).
    public var offersLinkItems: Bool
    /// The menu offered items for an image (copy, save or open the image).
    public var offersImageItems: Bool
    /// The menu offered items for audio or video. `ContextMenuRequest` has no media target yet, so this changes nothing
    /// today.
    public var offersMediaItems: Bool
    /// The menu offered items for a frame (open or reload the frame), which the engine does only for a click in a
    /// subframe.
    public var offersFrameItems: Bool
    /// The editing items the menu offered, enabled or not: Copy is the selection's Copy when the target is not
    /// editable.
    public var offeredEditItems: ContextMenuEditFlags
    /// The editing items the menu offered enabled, which the engine validated itself.
    public var enabledEditItems: ContextMenuEditFlags

    public init(
        offersLinkItems: Bool = false,
        offersImageItems: Bool = false,
        offersMediaItems: Bool = false,
        offersFrameItems: Bool = false,
        offeredEditItems: ContextMenuEditFlags = [],
        enabledEditItems: ContextMenuEditFlags = []
    ) {
        self.offersLinkItems = offersLinkItems
        self.offersImageItems = offersImageItems
        self.offersMediaItems = offersMediaItems
        self.offersFrameItems = offersFrameItems
        self.offeredEditItems = offeredEditItems
        self.enabledEditItems = enabledEditItems
    }
}

/// What a page script saw of the click in one frame.
public struct ContextMenuPageReport: Equatable, Sendable {
    /// The frame the report came from.
    public var frameURL: URL?
    public var isMainFrame: Bool
    /// The link under the pointer and its text, nil when there is none.
    public var linkURL: URL?
    public var linkText: String?
    /// The source of the image under the pointer, nil when there is none.
    public var imageURL: URL?
    /// The frame's selected text, empty when nothing is selected.
    public var selectionText: String
    /// True when the target is a field the person can type in.
    public var isEditable: Bool

    public init(
        frameURL: URL?,
        isMainFrame: Bool,
        linkURL: URL? = nil,
        linkText: String? = nil,
        imageURL: URL? = nil,
        selectionText: String = "",
        isEditable: Bool = false
    ) {
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
        self.linkURL = linkURL
        self.linkText = linkText
        self.imageURL = imageURL
        self.selectionText = selectionText
        self.isEditable = isEditable
    }
}

/// Merges the engine's menu hints with the page's reports into the request Bow builds its menu from.
public enum ContextMenuTargets {
    /// The editing items that mean the target is a field: Copy and Select All also come with a selection or a page.
    static let fieldOnlyEditItems: ContextMenuEditFlags = [.canUndo, .canRedo, .canCut, .canPaste, .canDelete]

    /// The report that belongs to this click, from `reports` (those that arrived since the right mouse down that
    /// opened the menu, oldest first): the last from a subframe when the menu offered frame items, else the last from
    /// the main frame, else the last.
    public static func clickReport(hints: ContextMenuHints, reports: [ContextMenuPageReport]) -> ContextMenuPageReport?
    {
        if hints.offersFrameItems, let report = reports.last(where: { !$0.isMainFrame }) {
            return report
        }
        return reports.last(where: \.isMainFrame) ?? reports.last
    }

    /// The request for this click. A kind of target is kept only when the menu and the click's report agree on it,
    /// so a click with no report keeps only what the menu alone can say: editing and navigation.
    public static func request(
        hints: ContextMenuHints,
        reports: [ContextMenuPageReport],
        profileID: ProfileID,
        position: PagePoint,
        pageURL: URL?,
        canGoBack: Bool,
        canGoForward: Bool
    ) -> ContextMenuRequest {
        let report = clickReport(hints: hints, reports: reports)
        let linkURL = hints.offersLinkItems ? report?.linkURL : nil
        let isEditable = !hints.offeredEditItems.isDisjoint(with: fieldOnlyEditItems) || report?.isEditable == true
        let offersCopy = hints.offeredEditItems.contains(.canCopy)
        return ContextMenuRequest(
            profileID: profileID,
            position: position,
            pageURL: pageURL,
            frameURL: report?.isMainFrame == false ? report?.frameURL : nil,
            linkURL: linkURL,
            linkText: linkURL == nil ? nil : report?.linkText,
            imageURL: hints.offersImageItems ? report?.imageURL : nil,
            selectionText: offersCopy && !isEditable ? report?.selectionText ?? "" : "",
            isEditable: isEditable,
            editFlags: isEditable ? hints.enabledEditItems : [],
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
    }
}
