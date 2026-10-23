import CoreGraphics
import Foundation

// Little Arc's decisions: where a link from another app opens, which Spaces a Little Arc page can move into and which
// key moves it, and where the window goes. Pure functions, so the app applies the results and the rules stay easy to
// test.

/// Little Arc: the small floating window a link from another app opens in, so it does not land among the person's
/// tabs. Its page can move into a Space of the browser window, keeping the live page, or close with the window.
public enum LittleArc {
    /// Whether "links from other apps open in Little Arc" is on when the person never set it: on, as in Arc.
    public static let opensExternalLinksByDefault = true

    /// Where a link from another app opens.
    public enum Opening: Equatable, Sendable {
        /// In a new Little Arc window.
        case littleArc
        /// In a new tab of a browser window, as without Little Arc.
        case browserWindow
    }

    /// Where a link from another app opens: in Little Arc when the setting is on (`setting` is nil when the person
    /// never set it, which means `opensExternalLinksByDefault`) and a Space can give the page its profile
    /// (`hasSpace`): the Space on screen in a browser window, or with no browser window open the Space shown last, as
    /// Arc opens Little Arc with no window open. Otherwise in a browser window as before, which opens a new window
    /// when none is open.
    public static func opening(setting: Bool?, hasSpace: Bool) -> Opening {
        guard setting ?? opensExternalLinksByDefault, hasSpace else { return .browserWindow }
        return .littleArc
    }

    /// A Space a Little Arc page can move into, as its move menu lists it.
    public struct MoveTarget: Equatable, Sendable {
        public var spaceID: SidebarSpaceID
        public var title: String
        /// The Space's number, 1 for the first: Ctrl and the number moves the page there. Nil past the ninth Space.
        public var shortcutNumber: Int?
        /// False for a Space of another profile: a live page cannot change profile, so it cannot move there.
        public var isEnabled: Bool
        /// True for the Space the browser window shows, where Open in Bow (Cmd+O) moves the page.
        public var isOnScreen: Bool

        public init(
            spaceID: SidebarSpaceID, title: String, shortcutNumber: Int?, isEnabled: Bool, isOnScreen: Bool
        ) {
            self.spaceID = spaceID
            self.title = title
            self.shortcutNumber = shortcutNumber
            self.isEnabled = isEnabled
            self.isOnScreen = isOnScreen
        }
    }

    /// Every Space of `graph` (the browser window's sidebar), in sidebar order, as a place the page of profile
    /// `profileID` can move into. Only Spaces of that profile are enabled.
    public static func moveTargets(in graph: SidebarGraph, profileID: SidebarProfileID) -> [MoveTarget] {
        graph.spaces.enumerated().map { index, space in
            let number = index + 1
            return MoveTarget(
                spaceID: space.id,
                title: space.title,
                shortcutNumber: number <= SidebarGraph.spaceShortcutLimit ? number : nil,
                isEnabled: space.profileID == profileID,
                isOnScreen: space.id == graph.activeSpaceID)
        }
    }

    /// The Space Open in Bow (Cmd+O) moves the page into: the Space on screen when it can take the page, else none.
    public static func openTarget(in targets: [MoveTarget]) -> MoveTarget? {
        targets.first { $0.isOnScreen && $0.isEnabled }
    }

    /// Whether Open in Bow can act: with a browser window open, when the Space on screen can take the page
    /// (`openTarget`); with none, always, because it opens a new window on a Space of the page's profile.
    public static func canOpenInBow(hasBrowserWindow: Bool, targets: [MoveTarget]) -> Bool {
        !hasBrowserWindow || openTarget(in: targets) != nil
    }

    /// The Space of `graph` (the sidebar shown last) a new browser window shows when Open in Bow runs with no browser
    /// window open, so the page of profile `profileID` can move into it: the Space on screen when it has that
    /// profile, else the first Space of that profile in sidebar order, else none (Open in Bow then does nothing).
    public static func newWindowSpace(in graph: SidebarGraph, profileID: SidebarProfileID) -> SidebarSpaceID? {
        LinkRouting.spaceID(forProfile: profileID, in: graph)
    }

    /// A main menu command that acts on a page, as Little Arc answers it while it is the key window.
    public enum MenuCommand: Equatable, Sendable, CaseIterable {
        case reload, stop, back, forward
        /// Open Location (Cmd+L): focuses Little Arc's address.
        case openLocation
        /// Find, Find Next and Find Previous.
        case find
    }

    /// Whether a main menu command is enabled while Little Arc is key, for its page's `controls`. Little Arc takes
    /// every one of them, so none reaches the browser window behind it: reload, stop, back, forward and Open Location
    /// act on Little Arc's page (as Arc's Cmd+R and Cmd+L do), and find stays disabled, because Arc's documentation
    /// gives Little Arc no find bar.
    public static func isEnabled(_ command: MenuCommand, controls: NavigationControls) -> Bool {
        switch command {
        case .reload, .openLocation: controls.canReload
        case .stop: controls.canStop
        case .back: controls.canGoBack
        case .forward: controls.canGoForward
        case .find: false
        }
    }

    /// Whether the app keeps running when its last browser window closes: an open Little Arc window counts as a
    /// window, so Bow stays open while one is (as Arc does).
    public static func keepsAppRunning(openLittleArcWindows: Int) -> Bool {
        openLittleArcWindows > 0
    }

    /// Whether a Little Arc window that has just closed was the app's last window, so the last window rule (quit, or
    /// wait for the downloads of closed tabs) runs now: no other Little Arc window is open (`openLittleArcWindows`
    /// counts those left) and no browser or other window is open, on screen or in the Dock (`hasOtherWindow`).
    /// AppKit never asks again on its own, because it does not count Little Arc's panels as windows.
    public static func closeEndsLastWindow(openLittleArcWindows: Int, hasOtherWindow: Bool) -> Bool {
        openLittleArcWindows == 0 && !hasOtherWindow
    }

    /// The Space Ctrl and `number` moves the page into, or nil when that number names no Space or a Space that cannot
    /// take the page.
    public static func target(shortcutNumber number: Int, in targets: [MoveTarget]) -> MoveTarget? {
        targets.first { $0.shortcutNumber == number && $0.isEnabled }
    }

    /// The window's size when the screen has room: compact, a little narrower than a browser window.
    public static let defaultSize = CGSize(width: 900, height: 660)
    /// The smallest window, so a page still reads.
    public static let minimumSize = CGSize(width: 420, height: 320)
    /// The room kept between the window and each edge of the screen when the screen is small.
    public static let margin: CGFloat = 40

    /// The window's frame on a screen whose usable area (without the menu bar and the Dock) is `visibleFrame`:
    /// `defaultSize`, shrunk to fit inside the area less `margin` on each side but never below `minimumSize`, centered
    /// in the area on whole points.
    public static func frame(in visibleFrame: CGRect) -> CGRect {
        let width = max(min(defaultSize.width, visibleFrame.width - 2 * margin), minimumSize.width)
        let height = max(min(defaultSize.height, visibleFrame.height - 2 * margin), minimumSize.height)
        return CGRect(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: (visibleFrame.midY - height / 2).rounded(),
            width: width,
            height: height)
    }

    /// The screen a new Little Arc window opens on, as an index into `screens` (each screen's whole frame): the one
    /// under the pointer, so the window shows where the person is looking (the app they clicked the link in), else
    /// `fallback` (the screen of the key window or the main screen), else the first. Nil when there is no screen.
    public static func screenIndex(pointer: CGPoint, screens: [CGRect], fallback: Int?) -> Int? {
        if let index = screens.firstIndex(where: { $0.contains(pointer) }) { return index }
        if let fallback, screens.indices.contains(fallback) { return fallback }
        return screens.isEmpty ? nil : 0
    }
}
