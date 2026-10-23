import BowCore
import Foundation

/// Where the app keeps its own settings. Read and write through `defaults`, never `UserDefaults.standard`:
/// e2e runs point it at a throwaway suite so they never read or change the maintainer's settings.
@MainActor
enum AppSettings {
    static var defaults: UserDefaults = .standard

    /// Posted on the main thread after `showsToolbar` changes, so every open window follows.
    static let toolbarVisibilityChanged = Notification.Name("dev.bowbrowser.toolbar-visibility-changed")
    static let showsToolbarKey = "showsToolbar"

    /// Whether windows show the sidebar's toolbar row (back, forward, reload) and URL field; true until the person
    /// hides them with View > Hide Toolbar. One setting for every window, kept across launches.
    static var showsToolbar: Bool {
        get { defaults.object(forKey: showsToolbarKey) as? Bool ?? true }
        set {
            guard newValue != showsToolbar else { return }
            defaults.set(newValue, forKey: showsToolbarKey)
            NotificationCenter.default.post(name: toolbarVisibilityChanged, object: nil)
        }
    }

    /// Posted on the main thread after `windowLayout` changes, so every open window follows.
    static let windowLayoutChanged = Notification.Name("dev.bowbrowser.window-layout-changed")
    static let windowLayoutKey = "windowLayout"

    /// Where windows keep their tabs: the sidebar (the default) or the top tabs layout, chosen with View > Use Top
    /// Tabs. One setting for every window, kept across launches.
    static var windowLayout: WindowLayout {
        get { WindowLayout(stored: defaults.string(forKey: windowLayoutKey)) }
        set {
            guard newValue != windowLayout else { return }
            defaults.set(newValue.rawValue, forKey: windowLayoutKey)
            NotificationCenter.default.post(name: windowLayoutChanged, object: nil)
        }
    }
}
