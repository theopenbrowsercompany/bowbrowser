import AppKit
import BowCore

/// The window's back, forward and reload buttons: plain icons in a row (`view`), which the window places in the
/// sidebar's top row beside the window buttons. The reload button turns into a stop button while the page loads,
/// which is how the row shows the loading state. The window's `NavigationFeature` pushes every change of its
/// `NavigationControls` through `show(_:)`; the buttons never validate themselves, so they change exactly when the
/// selected tab's state does.
@MainActor
final class NavigationToolbar: NSObject {
    enum Item: String, CaseIterable {
        case back, forward, reload
    }

    /// The icons' point size.
    static let symbolSize: CGFloat = 17

    let backButton = NavigationToolbar.button(symbol: "chevron.left", label: "Back")
    let forwardButton = NavigationToolbar.button(symbol: "chevron.right", label: "Forward")
    /// Reload while idle, stop while loading.
    let reloadButton = NavigationToolbar.button(symbol: "arrow.clockwise", label: "Reload")
    /// The three buttons in a row.
    let view: NSStackView

    override init() {
        view = NSStackView(views: [backButton, forwardButton, reloadButton])
        view.orientation = .horizontal
        view.spacing = 4
        super.init()
    }

    /// The button for `item`.
    func button(_ item: Item) -> NSButton {
        switch item {
        case .back: backButton
        case .forward: forwardButton
        case .reload: reloadButton
        }
    }

    /// Sends the buttons' actions to `target`. The page title stays the window's title (the Window menu and Mission
    /// Control show it) but is not drawn.
    func install(in window: NSWindow, target: NavigationFeature) {
        backButton.target = target
        backButton.action = #selector(NavigationFeature.goBack(_:))
        forwardButton.target = target
        forwardButton.action = #selector(NavigationFeature.goForward(_:))
        reloadButton.target = target
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

    private static func button(symbol: String, label: String) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        button.contentTintColor = BowBrand.soft
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
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
