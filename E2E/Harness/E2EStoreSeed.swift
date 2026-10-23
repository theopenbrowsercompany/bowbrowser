import Foundation

/// A sidebar for `E2EStoreSeedApp.openWindow(seeded:)` to build before its window opens: Spaces in order, each with
/// its pinned and today items.
struct E2ESeed {
    var spaces: [E2ESeedSpace]
    /// The name of the Space the window shows; nil shows the first.
    var activeSpace: String?

    init(spaces: [E2ESeedSpace], activeSpace: String? = nil) {
        self.spaces = spaces
        self.activeSpace = activeSpace
    }
}

/// One Space of an `E2ESeed`. Its name also names it in `E2ESeededWindow.spaceIDs`, so names must be unique.
struct E2ESeedSpace {
    var name: String
    /// The profile the Space's tabs open in. `.new` creates the profile; two Spaces naming the same new profile ID
    /// share it.
    var profile: E2EWindowProfile
    var pinned: [E2ESeedItem]
    var today: [E2ESeedItem]

    init(_ name: String, profile: E2EWindowProfile = .test, pinned: [E2ESeedItem] = [], today: [E2ESeedItem] = []) {
        self.name = name
        self.profile = profile
        self.pinned = pinned
        self.today = today
    }
}

/// A tab or folder of an `E2ESeedSpace`. Its name names it in `E2ESeededWindow.itemIDs`, so names must be unique
/// across the whole seed.
indirect enum E2ESeedItem {
    /// A tab saved on `url`, titled `name` until its page loads and names it.
    case tab(_ name: String, url: URL)
    /// A folder called `name` holding `items`, open unless `expanded` is false.
    case folder(_ name: String, expanded: Bool = true, _ items: [E2ESeedItem])

    var name: String {
        switch self {
        case .tab(let name, _), .folder(let name, _, _): name
        }
    }
}

/// The window `E2EStoreSeedApp.openWindow(seeded:)` opened, and the store ID of everything it created.
@MainActor
struct E2ESeededWindow {
    /// The page of the tab the window shows: the active Space's selected tab, or the home page when that Space has
    /// no tab.
    var page: any E2EPage
    /// The ID of each Space, by its name.
    var spaceIDs: [String: String]
    /// The ID of each tab and folder, by its name.
    var itemIDs: [String: String]
}

/// Building a test's sidebar in one call: Spaces, nested folders and pinned or today tabs, created through the
/// sidebar store before the window that shows them opens, so a test starts from the layout it needs.
@MainActor
protocol E2EStoreSeedApp: E2EApp {
    /// Builds `seed` in a new sidebar of the test's own, then opens an off-screen window on it the way the app opens
    /// a saved sidebar at launch, and returns the window's page with every created ID. Throws when a name repeats or
    /// the store refuses an item (for example a folder in a place that cannot hold one).
    func openWindow(seeded seed: E2ESeed) async throws -> E2ESeededWindow
}
