import AppKit
import BowCore

/// The window toolbar's back, forward and reload buttons. The reload button turns into a stop button while the
/// page loads, which is how the toolbar shows the loading state. The window's `NavigationFeature` pushes every
/// change of its `NavigationControls` through `show(_:)`; the buttons never validate themselves, so they change
/// exactly when the selected tab's state does.
@MainActor
final class NavigationToolbar: NSObject, NSToolbarDelegate {
    enum Item: String, CaseIterable {
        case back, forward, reload

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("bow.navigation.\(rawValue)") }
    }

    let backButton = NavigationToolbar.button(symbol: "chevron.left", label: "Back")
    let forwardButton = NavigationToolbar.button(symbol: "chevron.right", label: "Forward")
    /// Reload while idle, stop while loading.
    let reloadButton = NavigationToolbar.button(symbol: "arrow.clockwise", label: "Reload")

    private let toolbar = NSToolbar(identifier: "bow.browser")

    /// The button for `item`.
    func button(_ item: Item) -> NSButton {
        switch item {
        case .back: backButton
        case .forward: forwardButton
        case .reload: reloadButton
        }
    }

    /// Adds the toolbar to `window`, sending the buttons' actions to `target`.
    func install(in window: NSWindow, target: NavigationFeature) {
        backButton.target = target
        backButton.action = #selector(NavigationFeature.goBack(_:))
        forwardButton.target = target
        forwardButton.action = #selector(NavigationFeature.goForward(_:))
        reloadButton.target = target
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // The page title stays the window's title (the Window menu and Mission Control show it) but is not drawn,
        // so the buttons sit right after the window buttons, as in other browsers.
        window.titleVisibility = .hidden
        show(.disabled)
    }

    /// Shows `controls`: enables each button by what it can do now, and shows stop instead of reload while loading.
    func show(_ controls: NavigationControls) {
        backButton.isEnabled = controls.canGoBack
        forwardButton.isEnabled = controls.canGoForward
        if controls.isLoading {
            Self.configure(reloadButton, symbol: "xmark", label: "Stop")
            reloadButton.action = #selector(NavigationFeature.stopLoading(_:))
            reloadButton.isEnabled = controls.canStop
        } else {
            Self.configure(reloadButton, symbol: "arrow.clockwise", label: "Reload")
            reloadButton.action = #selector(NavigationFeature.reloadPage(_:))
            reloadButton.isEnabled = controls.canReload
        }
    }

    /// The buttons sit at the leading edge, next to the window buttons, as in other browsers.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Item.allCases.map(\.identifier) + [.flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Item.allCases.map(\.identifier) + [.flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let item = Item.allCases.first(where: { $0.identifier == itemIdentifier }) else { return nil }
        let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
        let button = button(item)
        toolbarItem.view = button
        toolbarItem.label = button.toolTip ?? ""
        // `show(_:)` sets each button's state; validation would fight it.
        toolbarItem.autovalidates = false
        return toolbarItem
    }

    private static func button(symbol: String, label: String) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        configure(button, symbol: symbol, label: label)
        return button
    }

    private static func configure(_ button: NSButton, symbol: String, label: String) {
        guard button.toolTip != label else { return }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
}
