import Foundation

// How the app answers a context menu a page asks for (a right click, or Control-click), and what runs when the
// person chooses an item. The engine asks on a later main thread task, so the app may show the menu as modal UI.

/// A point in a page, in points from the top left of the view that shows it.
public struct PagePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// What an editable field under the pointer can do now.
public struct ContextMenuEditFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let canUndo = ContextMenuEditFlags(rawValue: 1 << 0)
    public static let canRedo = ContextMenuEditFlags(rawValue: 1 << 1)
    public static let canCut = ContextMenuEditFlags(rawValue: 1 << 2)
    public static let canCopy = ContextMenuEditFlags(rawValue: 1 << 3)
    public static let canPaste = ContextMenuEditFlags(rawValue: 1 << 4)
    public static let canDelete = ContextMenuEditFlags(rawValue: 1 << 5)
    public static let canSelectAll = ContextMenuEditFlags(rawValue: 1 << 6)
}

/// What the person asked for a context menu on. Copied out of the engine when it asks, so it stays valid after the
/// page moves on.
public struct ContextMenuRequest: Equatable, Sendable {
    /// The profile of the tab that asked.
    public var profileID: ProfileID
    /// Where the menu was asked for.
    public var position: PagePoint
    /// The page and the frame the pointer was in (the same for the main frame).
    public var pageURL: URL?
    public var frameURL: URL?
    /// The link under the pointer, nil when there is none.
    public var linkURL: URL?
    /// The link's text. Nil when there is no link, and always nil with the engine version Bow uses, which does not
    /// report it.
    public var linkText: String?
    /// The source of the image under the pointer, nil when there is none.
    public var imageURL: URL?
    /// The selected text, empty when nothing is selected.
    public var selectionText: String
    /// True when the pointer is over a field the person can type in; `editFlags` then says what it can do.
    public var isEditable: Bool
    public var editFlags: ContextMenuEditFlags
    /// Whether the tab could go back or forward when the menu was asked for.
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init(
        profileID: ProfileID,
        position: PagePoint,
        pageURL: URL? = nil,
        frameURL: URL? = nil,
        linkURL: URL? = nil,
        linkText: String? = nil,
        imageURL: URL? = nil,
        selectionText: String = "",
        isEditable: Bool = false,
        editFlags: ContextMenuEditFlags = [],
        canGoBack: Bool = false,
        canGoForward: Bool = false
    ) {
        self.profileID = profileID
        self.position = position
        self.pageURL = pageURL
        self.frameURL = frameURL
        self.linkURL = linkURL
        self.linkText = linkText
        self.imageURL = imageURL
        self.selectionText = selectionText
        self.isEditable = isEditable
        self.editFlags = editFlags
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}

/// What a context menu item does when chosen. The app runs a chosen command first
/// (`EngineTabDelegate.tab(_:runContextMenuCommand:request:)`); one it leaves runs in the engine as described below.
public enum ContextMenuCommand: Hashable, Sendable {
    /// Opens the link in a new tab. Only the app can: the engine does nothing with it.
    case openLinkInNewTab
    /// Puts the link's address, or the image's, on the pasteboard.
    case copyLinkAddress
    case copyImageAddress
    /// Puts the image itself on the pasteboard. Only the app can: the engine has no command for it, so it does nothing.
    case copyImage
    /// The tab's own navigation.
    case back
    case forward
    case reload
    /// Editing in the frame the menu was asked in.
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    /// Opens the engine's web inspector for the tab, inspecting the element at the menu's position.
    case inspect
    /// A feature's own item, by an identifier it chose. The engine does nothing with it.
    case custom(String)
}

/// One item of a menu the app shows.
public struct ContextMenuItem: Hashable, Sendable {
    public var title: String
    /// Nil for a separator.
    public var command: ContextMenuCommand?
    public var isEnabled: Bool

    public init(_ title: String, _ command: ContextMenuCommand, isEnabled: Bool = true) {
        self.title = title
        self.command = command
        self.isEnabled = isEnabled
    }

    private init(separator: Void) {
        title = ""
        command = nil
        isEnabled = false
    }

    public static let separator = ContextMenuItem(separator: ())

    public var isSeparator: Bool { command == nil }
}

/// The app's answer to a context menu request.
public enum ContextMenuDecision: Equatable, Sendable {
    /// Show these items, in order, as a native menu at the pointer.
    case show([ContextMenuItem])
    /// Show the engine's own menu, as a native menu at the pointer. The default without an answer.
    case engineDefault
    /// Show nothing.
    case none
}

/// Bow's own web page menu, the way Chromium based browsers (and Arc) build theirs: link items, then image items,
/// then editing or the selection, or navigation on a bare page, and Inspect last. A pure function, so the window
/// applies it and the rules stay easy to change and test.
public enum ContextMenuPolicy {
    /// What a window shows when no feature answers.
    public static func defaultDecision(for request: ContextMenuRequest) -> ContextMenuDecision {
        .show(items(for: request))
    }

    public static func items(for request: ContextMenuRequest) -> [ContextMenuItem] {
        var groups: [[ContextMenuItem]] = []
        if request.linkURL != nil {
            groups.append([
                ContextMenuItem("Open Link in New Tab", .openLinkInNewTab),
                ContextMenuItem("Copy Link Address", .copyLinkAddress),
            ])
        }
        if request.imageURL != nil {
            groups.append([
                ContextMenuItem("Copy Image", .copyImage),
                ContextMenuItem("Copy Image Address", .copyImageAddress),
            ])
        }
        if request.isEditable {
            let flags = request.editFlags
            groups.append([
                ContextMenuItem("Undo", .undo, isEnabled: flags.contains(.canUndo)),
                ContextMenuItem("Redo", .redo, isEnabled: flags.contains(.canRedo)),
            ])
            groups.append([
                ContextMenuItem("Cut", .cut, isEnabled: flags.contains(.canCut)),
                ContextMenuItem("Copy", .copy, isEnabled: flags.contains(.canCopy)),
                ContextMenuItem("Paste", .paste, isEnabled: flags.contains(.canPaste)),
                ContextMenuItem("Select All", .selectAll, isEnabled: flags.contains(.canSelectAll)),
            ])
        } else if !request.selectionText.isEmpty {
            groups.append([ContextMenuItem("Copy", .copy)])
        } else if request.linkURL == nil && request.imageURL == nil {
            groups.append([
                ContextMenuItem("Back", .back, isEnabled: request.canGoBack),
                ContextMenuItem("Forward", .forward, isEnabled: request.canGoForward),
                ContextMenuItem("Reload", .reload),
            ])
        }
        groups.append([ContextMenuItem("Inspect", .inspect)])
        return Array(groups.joined(separator: [ContextMenuItem.separator]))
    }
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, decideContextMenu request: ContextMenuRequest) -> ContextMenuDecision {
        .engineDefault
    }

    public func tab(
        _ tab: any EngineTab, runContextMenuCommand command: ContextMenuCommand, request: ContextMenuRequest
    ) -> Bool {
        false
    }
}
