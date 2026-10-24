import Foundation

/// The design area's fixed starting window, so a capture reads the same whatever the hour, the run or the screen:
/// the Spaces 🏠 Home (default theme) and 💼 Work (the Blue preset), six Favorites, a pinned tab, a pinned folder of
/// two and three today tabs in Home and two today tabs in Work, each page linking its own icon from
/// https://bow.test/design/icons/, a clock fixed at 10:00, and a 1200 by 800 point window showing Home's Notes.
/// Determinism here is for readable captures; nothing compares their pixels.
@MainActor
enum E2EDesignFixture {
    static let home = "Home"
    static let homeIcon = "🏠"
    static let work = "Work"
    static let workIcon = "💼"
    static let workTheme = "Blue"
    static let favorites = ["Mail", "Calendar", "Music", "Maps", "News", "Photos"]
    static let pinnedTab = "Docs"
    static let folder = "Projects"
    static let folderTabs = ["Plan", "Roadmap"]
    static let today = ["Notes", "Reading", "Recipes"]
    static let workToday = ["Standup", "Tickets"]
    /// The tab the window shows when it opens.
    static let active = "Notes"
    static let width = 1200.0
    static let height = 800.0
    /// The hour the fixed clock reads, which the start screen greets as morning.
    static let clockHour = 10
    /// Where every fixture page's icon is served from.
    static let iconPrefix = "https://bow.test/design/icons/"

    /// 10:00 local time on 23 October 2026.
    static var clock: Date {
        get throws {
            let parts = DateComponents(year: 2026, month: 10, day: 23, hour: clockHour)
            guard let date = Calendar.current.date(from: parts) else { throw E2EError("cannot make the fixed clock") }
            return date
        }
    }

    /// The fixture page titled `title`, linking `icons/<title in lower case>.png` as its icon.
    static func url(_ title: String) -> URL {
        E2EFixture.url("design/page.html?title=\(title)&icon=\(title.lowercased())")
    }

    static var seed: E2ESeed {
        func tabs(_ names: [String]) -> [E2ESeedItem] { names.map { .tab($0, url: url($0)) } }
        return E2ESeed(
            spaces: [
                E2ESeedSpace(
                    home, icon: homeIcon, favorites: tabs(favorites),
                    pinned: [.tab(pinnedTab, url: url(pinnedTab)), .folder(folder, tabs(folderTabs))],
                    today: tabs(today)),
                E2ESeedSpace(work, icon: workIcon, theme: workTheme, today: tabs(workToday)),
            ], activeSpace: home, activeTab: active)
    }

    /// Fixes the clock, opens the fixture's window at 1200 by 800 points and waits until Notes has loaded and the
    /// sidebar shows its icon. Returns the window, whose page is Notes's.
    static func open(_ run: E2ERun) async throws -> E2ESeededWindow {
        guard let seeds = run.app as? any E2EStoreSeedApp, let design = run.app as? any E2EDesignApp else {
            throw E2EError("the app lacks the seed or design hooks")
        }
        return try await run.step("open the design fixture", timeout: E2ETimeouts.firstLoad) {
            try design.useClock(try clock)
            let window = try await seeds.openWindow(seeded: seed)
            try design.resizeWindow(of: window.page, width: width, height: height)
            _ = try await window.page.waitForLoad(after: 0)
            try await waitForIcon(run, besides: window.page)
            return window
        }
    }

    /// Waits until the sidebar of `page`'s window shows an icon for the tab the window shows.
    static func waitForIcon(_ run: E2ERun, besides page: any E2EPage) async throws {
        guard let design = run.app as? any E2EDesignApp else { throw E2EError("the app has no design hooks") }
        _ = try await E2EWaits.until { try design.fixtureState(of: page).activeTabHasIcon }
        guard try design.fixtureState(of: page).activeTabHasIcon else {
            throw E2EError("the sidebar shows no icon for the shown tab")
        }
    }

    /// The folder design captures go to: `build/e2e/<run>/design/`.
    static func folder(_ run: E2ERun) -> URL {
        run.outputDirectory.appendingPathComponent("design", isDirectory: true)
    }

    /// Writes `<name>.png` of `page`'s window (or its sidebar) to the design folder for the maintainer to look at.
    /// A capture never fails a test: one that cannot be taken or written prints `NOTE design capture <name>: <why>`.
    /// Returns the PNG data, nil when there is none.
    @discardableResult
    static func capture(_ run: E2ERun, _ page: any E2EPage, _ region: E2EDesignRegion, _ name: String) async -> Data? {
        guard let design = run.app as? any E2EDesignApp else {
            run.note("design capture \(name): the app has no design hooks")
            return nil
        }
        let data: Data
        do {
            data = try await design.capture(of: page, region)
        } catch {
            run.note("design capture \(name): \(error)")
            return nil
        }
        do {
            let folder = folder(run)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            run.note("design capture \(name): \(error.localizedDescription)")
        }
        return data
    }
}

/// What `E2EDesignApp.fixtureState(of:)` reads from a window's sidebar store and sidebar.
struct E2EDesignFixtureState: Equatable {
    struct Space: Equatable, CustomStringConvertible {
        var name: String
        /// The Space's emoji icon, nil without one.
        var icon: String?
        /// The Space's theme color as `#RRGGBB`, nil for the default theme.
        var theme: String?
        /// The Space's pinned and today items: a tab's title, or a folder as `<name>[<child>,<child>]`.
        var pinned: [String]
        var today: [String]

        var description: String {
            "\(icon ?? "")\(name)(\(theme ?? "default")) pinned=\(pinned) today=\(today)"
        }
    }

    var spaces: [Space]
    /// The titles of the Favorites the Space on screen shows, in order.
    var favorites: [String]
    /// The saved title of the tab the window shows, nil when it shows none.
    var activeTab: String?
    /// True when the sidebar has an icon for the tab the window shows.
    var activeTabHasIcon: Bool
}
