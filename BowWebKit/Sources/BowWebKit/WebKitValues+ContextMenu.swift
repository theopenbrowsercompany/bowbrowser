import AppKit
import BowCore
import WebKit

// WebKit's context menu and the target script's messages as BowCore's engine neutral values: the menu's items say
// which kinds of target the click hit (`ContextMenuHints`), and the script says what they are
// (`ContextMenuPageReport`). `ContextMenuTargets` merges them; nothing here decides.

/// The identifiers WebKit gives its own context menu items (`NSMenuItem.identifier`, public API), as WebKit's private
/// `WKMenuItemIdentifiersPrivate.h` names them. They are strings compared with what WebKit put in the menu, never
/// called, so a renamed one only drops its kind of target from Bow's menu; ContextMenuTests fails when WebKit renames
/// one Bow relies on.
enum WebKitMenuItem {
    static let linkItems: Set<String> = [
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierCopyLink",
    ]
    static let imageItems: Set<String> = [
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierCopyCroppedImage", "WKMenuItemIdentifierRevealImage",
    ]
    static let mediaItems: Set<String> = [
        "WKMenuItemIdentifierOpenMediaInNewWindow", "WKMenuItemIdentifierDownloadMedia",
        "WKMenuItemIdentifierCopyMediaLink", "WKMenuItemIdentifierShowHideMediaControls",
        "WKMenuItemIdentifierToggleFullScreen", "WKMenuItemIdentifierToggleEnhancedFullScreen",
    ]
    static let frameItems: Set<String> = ["WKMenuItemIdentifierOpenFrameInNewWindow"]
    static let editItems: [String: ContextMenuEditFlags] = [
        "WKMenuItemIdentifierCut": .canCut,
        "WKMenuItemIdentifierCopy": .canCopy,
        "WKMenuItemIdentifierPaste": .canPaste,
    ]
}

extension ContextMenuHints {
    /// The kinds of target WebKit's own menu `menu` offered items for.
    @MainActor
    init(_ menu: NSMenu) {
        self.init()
        for item in menu.items {
            guard let identifier = item.identifier?.rawValue else { continue }
            if WebKitMenuItem.linkItems.contains(identifier) { offersLinkItems = true }
            if WebKitMenuItem.imageItems.contains(identifier) { offersImageItems = true }
            if WebKitMenuItem.mediaItems.contains(identifier) { offersMediaItems = true }
            if WebKitMenuItem.frameItems.contains(identifier) { offersFrameItems = true }
            if let flag = WebKitMenuItem.editItems[identifier] {
                offeredEditItems.insert(flag)
                if item.isEnabled { enabledEditItems.insert(flag) }
            }
        }
    }
}

extension ContextMenuPageReport {
    /// The report in a message of the target script (Scripts/ContextMenuTarget.js) from a frame, nil when the body is
    /// not one. Whether the frame is the main one comes from WebKit, never from the script.
    init?(body: Any, isMainFrame: Bool) {
        guard let body = body as? [String: Any] else { return nil }
        func url(_ key: String) -> URL? {
            guard let text = body[key] as? String, !text.isEmpty else { return nil }
            return URL(string: text)
        }
        let linkText = (body["linkText"] as? String) ?? ""
        self.init(
            frameURL: url("frame"),
            isMainFrame: isMainFrame,
            linkURL: url("link"),
            linkText: linkText.isEmpty ? nil : linkText,
            imageURL: url("image"),
            selectionText: (body["selection"] as? String) ?? "",
            isEditable: (body["editable"] as? Bool) ?? false
        )
    }
}

extension PagePoint {
    /// `point` (in window coordinates) in `view`, in points from its top left.
    @MainActor
    init(window point: NSPoint, in view: NSView) {
        let local = view.convert(point, from: nil)
        self.init(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
    }
}
