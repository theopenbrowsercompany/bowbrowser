import AppKit
import BowCore

/// The empty state of a Space with no tabs: closing the Space's last tab, or switching to a Space that has none,
/// keeps the window open and fills the page area with the start screen (a greeting, a search pill that opens the
/// command bar, the profile's first Favorites as quick links and a hint naming the Space), never another Space's page.
/// An active tab with no page loaded (a lone pinned tab the person closed) shows a line and a Load Tab button instead
/// of a blank page area.
@MainActor
final class EmptySpaceFeature: NSResponder, BrowserWindowFeature {
    /// The empty state, over the page area; hidden while the page area shows a page.
    let emptyView: EmptySpaceView
    private weak var window: BrowserWindowController?

    init(window: BrowserWindowController) {
        self.window = window
        emptyView = EmptySpaceView()
        emptyView.isHidden = true
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        window.pageArea.addSubview(emptyView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: window.pageArea.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: window.pageArea.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: window.pageArea.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: window.pageArea.bottomAnchor),
        ])
        super.init()
        emptyView.startScreen.searchPill.target = self
        emptyView.startScreen.searchPill.action = #selector(openCommandBar(_:))
        emptyView.startScreen.openLink = { [weak self] item in self?.openFavorite(item) }
        emptyView.loadTabButton.target = self
        emptyView.loadTabButton.action = #selector(loadActiveTab(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shown while the page area shows no page, the window follows every store change with this: the start screen
    /// when the Space on screen has no tabs, else the unloaded tab state. Hidden while the window closes, since it
    /// loads nothing then. Each call reads the hour, the Space and its profile's Favorites again, so the screen follows
    /// a Space switch or a Favorite removed while it shows, and no timer outlives the window.
    func selectedTabChanged(_ tab: (any EngineTab)?) {
        guard let window, let space = window.store.graph.activeSpaceID, tab == nil, !window.isClosing else {
            emptyView.isHidden = true
            return
        }
        emptyView.isHidden = false
        let graph = window.store.graph
        // An active tab without a page (a pinned tab or Favorite the person closed) offers to load it.
        emptyView.showsUnloadedTab = window.tabList.activeID != nil || !graph.tabIDs(in: space).isEmpty
        guard !emptyView.showsUnloadedTab else { return }
        let sidebar = window.feature(SidebarFeature.self)
        let links = StartScreen.quickLinks(in: graph).compactMap { id -> StartQuickLink? in
            guard let item = graph[id], let saved = item.tab else { return nil }
            return StartQuickLink(
                item: id, title: FavoritesGridView.title(of: item, saved: saved), icon: sidebar?.favicon(for: id))
        }
        emptyView.startScreen.show(
            hour: StartScreen.hour(at: Date()), hint: StartScreen.hint(for: space, in: graph),
            quickLinks: links)
    }

    /// The search pill: opens the command bar empty, as File > New Tab (Cmd+T) does.
    @objc private func openCommandBar(_ sender: Any?) {
        guard let window else { return }
        if let bar = window.feature(CommandBarFeature.self) {
            bar.open(.newTab)
        } else {
            window.newTab(sender)
        }
    }

    /// A quick link: shows the Favorite in place, as clicking its tile in the sidebar does.
    private func openFavorite(_ item: SidebarItemID) {
        window?.feature(SidebarFeature.self)?.open(favorite: item)
    }

    /// Loads the active tab the unloaded state stands for, as choosing its row does.
    @objc private func loadActiveTab(_ sender: Any?) {
        guard let window, let id = window.tabList.activeID else { return }
        window.select(id)
    }
}

/// A plain Page colored view: the start screen for an empty Space, or, for an active tab with no page loaded, the Bow
/// mark, "This tab is not loaded" and a Load Tab button.
@MainActor
final class EmptySpaceView: NSView {
    /// The start screen, shown for an empty Space.
    let startScreen = StartScreenView()
    /// The unloaded tab state's Bow mark, from the brand kit, at 64 points.
    let markView = NSImageView()
    static let markSize: CGFloat = 64
    static let pillHeight: CGFloat = 32
    static let pillWidth: CGFloat = 112
    let messageLabel = NSTextField(labelWithString: "This tab is not loaded")
    let loadTabButton = NSButton(title: "Load Tab", target: nil, action: nil)
    private let unloadedStack: NSStackView

    /// Whether the view stands for an unloaded tab rather than an empty Space.
    var showsUnloadedTab = false {
        didSet {
            startScreen.isHidden = showsUnloadedTab
            unloadedStack.isHidden = !showsUnloadedTab
        }
    }

    init() {
        unloadedStack = NSStackView(views: [markView, messageLabel, loadTabButton])
        super.init(frame: .zero)
        // It fills the page card, which is White in both appearances, so it always draws light.
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = BowBrand.page.cgColor
        // A filled pill button: Jam Deep with white text.
        loadTabButton.isBordered = false
        loadTabButton.wantsLayer = true
        loadTabButton.layer?.backgroundColor = BowBrand.button.cgColor
        loadTabButton.layer?.cornerRadius = Self.pillHeight / 2
        loadTabButton.attributedTitle = NSAttributedString(
            string: loadTabButton.title,
            attributes: [.font: BowBrand.ui(weight: .semibold), .foregroundColor: NSColor.white])
        loadTabButton.translatesAutoresizingMaskIntoConstraints = false
        markView.image = NSImage(named: "BowMark")
        markView.imageScaling = .scaleProportionallyUpOrDown
        markView.setAccessibilityLabel("Bow")
        messageLabel.font = BowBrand.ui(15)
        messageLabel.textColor = BowBrand.soft
        unloadedStack.orientation = .vertical
        unloadedStack.spacing = 12
        unloadedStack.setCustomSpacing(16, after: markView)
        unloadedStack.isHidden = true
        for view in [startScreen, unloadedStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            startScreen.leadingAnchor.constraint(equalTo: leadingAnchor),
            startScreen.trailingAnchor.constraint(equalTo: trailingAnchor),
            startScreen.topAnchor.constraint(equalTo: topAnchor),
            startScreen.bottomAnchor.constraint(equalTo: bottomAnchor),
            unloadedStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            unloadedStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            markView.widthAnchor.constraint(equalToConstant: Self.markSize),
            markView.heightAnchor.constraint(equalToConstant: Self.markSize),
            loadTabButton.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            loadTabButton.widthAnchor.constraint(equalToConstant: Self.pillWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
