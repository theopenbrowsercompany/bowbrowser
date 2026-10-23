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
    /// share it, and must agree on whether it is persistent. Name a new profile after the test
    /// (`E2EStoreSeedApp.testProfileID()`), so it cannot clash with another test's. A new profile is created once
    /// per seed, so a second seeded window in the same test needs new profile IDs of its own.
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
    /// a saved sidebar at launch, and returns the window's page with every created ID. Throws when a name repeats, two
    /// Spaces disagree on whether one new profile is persistent, or the store refuses an item (for example a folder in a place that cannot hold one).
    func openWindow(seeded seed: E2ESeed) async throws -> E2ESeededWindow
    /// The ID of the running test's own profile (`E2EWindowProfile.test`), so a seed can name a new profile after
    /// its test (for example `testProfileID() + "-home"`) and no two tests share one. Throws once the test ended.
    func testProfileID() throws -> String
    /// What the sidebar store of `page`'s window holds under `id` (a Space ID or an item ID from
    /// `E2ESeededWindow`), read from the store's graph, nil when the ID names nothing there.
    func storeEntry(id: String, in page: any E2EPage) throws -> E2EStoreEntry?
}

/// A Space or an item as a window's sidebar store holds it (`E2EStoreSeedApp.storeEntry(id:in:)`).
struct E2EStoreEntry: Equatable, CustomStringConvertible {
    enum Kind: String {
        case space, tab, folder, other
    }

    var kind: Kind
    /// The Space's title, the folder's name, or the tab's saved title.
    var title: String
    /// Where an item sits: its parent folder's ID, or "pinned" or "today" when it sits right in its Space's
    /// section; nil for a Space.
    var parent: String?
    /// The ID of the Space the entry is or belongs to.
    var spaceID: String?
    /// The sidebar profile ID of that Space (the engine profile ID, "default" for the app's default profile).
    var profileID: String?

    var description: String {
        "\(kind.rawValue):\(title) parent=\(parent ?? "none") space=\(spaceID ?? "none") profile=\(profileID ?? "none")"
    }
}
