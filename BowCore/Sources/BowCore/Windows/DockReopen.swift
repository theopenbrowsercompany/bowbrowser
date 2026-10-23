import Foundation

/// What the app does when it is reopened (a click on its Dock icon, or launching it again while it runs).
public enum DockReopen {
    /// What a browser window looks like to the decision.
    public struct WindowState: Equatable, Sendable {
        public var isVisible: Bool
        public var isMiniaturized: Bool

        public init(isVisible: Bool, isMiniaturized: Bool) {
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
        }
    }

    public enum Action: Equatable, Sendable {
        /// Open a new browser window, on the sidebar's last shown Space.
        case openWindow
        /// Bring the minimized window at this index of the list back from the Dock.
        case restore(Int)
        /// Leave it to the system: a window is on screen, or the app is hidden and the system shows its windows again.
        case none
    }

    /// What reopening does. `windows` are the browser windows that are not closing, in order, the most recently used
    /// last; Little Arc and other panels are not in it, so a Little Arc window alone still opens a browser window, as
    /// in Arc. With no window: a new one. With a window on screen: nothing more (the system brings it forward).
    /// Otherwise, a minimized window comes back (the most recently used one) rather than another opening; windows that
    /// are neither shown nor minimized belong to a hidden app, which the system unhides. Quitting opens nothing.
    public static func decide(windows: [WindowState], isQuitting: Bool) -> Action {
        if isQuitting { return .none }
        if windows.isEmpty { return .openWindow }
        if windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) { return .none }
        if let index = windows.lastIndex(where: \.isMiniaturized) { return .restore(index) }
        return .none
    }
}
