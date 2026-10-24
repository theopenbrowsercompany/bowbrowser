import Foundation

/// The design area's shared helpers and its capture run. Each surface's checks live in its own
/// `Design<Surface>.swift` (frame, sidebar, Favorites, footer, command bar, start screen); all of them are area
/// `design`. The fixture they start from is `E2EDesignFixture`. `design.screens` writes named captures of the main
/// states to `build/e2e/<run>/design/` for the maintainer to look at; a capture never passes or fails a check.
/// Fixtures in E2E/Fixtures/design/.
@MainActor
enum DesignTests {
    static let all: [any E2ETest] = [DesignScreensTest()]

    /// The brand tokens (light, then dark).
    static let frameLight = "#FFF3E6"
    static let frameDark = "#2A1710"
    static let textLight = "#3A1F14"
    static let textDark = "#FFF3E6"
    static let activeLight = "#FFFFFF"
    static let activeDark = "#3D2519"
    static let apricot = "#FFC08A"
    static let jam = "#E8743B"
    static let blue = "#3B5BDB"

    static func design(_ run: E2ERun) throws -> any E2EDesignApp {
        guard let app = run.app as? any E2EDesignApp else { throw E2EError("the app has no design hooks") }
        return app
    }

    /// The fixture page titled `title`, with its own icon.
    static func url(_ title: String) -> URL {
        E2EDesignFixture.url(title)
    }

    /// Opens the design fixture (`E2EDesignFixture`) and returns the page it shows, Notes.
    static func openBrowsing(_ run: E2ERun) async throws -> any E2EPage {
        try await E2EDesignFixture.open(run).page
    }

    /// Opens the command bar over `page` with Command-T and waits until it shows.
    static func openCommandBar(_ run: E2ERun, over page: any E2EPage) async throws -> any E2ECommandBar {
        guard let menus = run.app as? any E2EMenuApp, let bars = run.app as? any E2ECommandBarApp else {
            throw E2EError("the app lacks the menu or command bar hooks")
        }
        try menus.chooseMenuItem(key: "t", modifiers: [.command], in: page)
        let bar = try bars.commandBar(of: page)
        _ = try await E2EWaits.until { bar.isShown }
        guard bar.isShown else { throw E2EError("the command bar did not open") }
        return bar
    }
}

/// The capture run: opens the design fixture, checks it is the fixed one (Spaces, icons, theme, Favorites, tabs,
/// page icons and the fixed clock), and writes browsing-light, sidebar-light, browsing-dark, sidebar-dark,
/// browsing-blue (the Work Space), top-tabs, command-bar, narrow and empty-space to `<run>/design/`. Takes the light
/// sidebar twice and checks the two bitmaps are identical, and checks the dark colors.
struct DesignScreensTest: E2ETest {
    let name = "design.screens"
    let checks = ["design.fixture", "design.capture_stable", "design.dark_colors"]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp, let start = run.app as? any E2EStartScreenApp,
            let profiles = run.app as? any E2EProfilesApp
        else { throw E2EError("the app lacks the window edges, start screen or profiles hooks") }
        typealias Fixture = E2EDesignFixture
        let window = try await Fixture.open(run)
        let notes = window.page
        let read = try await run.step("read the fixture", timeout: E2ETimeouts.step) {
            let icon = try await notes.string(
                """
                (async () => {
                  const link = document.querySelector('link[rel=icon]');
                  if (!link) return 'none';
                  const response = await fetch(link.href);
                  return `${link.href} ${response.status} ${response.headers.get('content-type')}`;
                })()
                """)
            return (try design.fixtureState(of: notes), icon)
        }

        let light = try await run.step("browsing", timeout: E2ETimeouts.step) {
            await Fixture.capture(run, notes, .window, "browsing-light")
            let first = await Fixture.capture(run, notes, .sidebar, "sidebar-light")
            try await E2EWaits.untilRendering(notes)
            let second = try await design.capture(of: notes, .sidebar)
            return (first, second)
        }
        run.check(
            "design.capture_stable", passed: light.0 != nil && light.0 == light.1,
            "first=\(light.0?.count ?? 0) bytes second=\(light.1.count) bytes identical=\(light.0 == light.1)")

        let dark = try await run.step("dark", timeout: E2ETimeouts.step) {
            try design.setDarkAppearance(true, of: notes)
            _ = try await E2EWaits.until { try design.look(of: notes).frame.frameColor == DesignTests.frameDark }
            await Fixture.capture(run, notes, .window, "browsing-dark")
            await Fixture.capture(run, notes, .sidebar, "sidebar-dark")
            let look = try design.look(of: notes)
            try design.setDarkAppearance(false, of: notes)
            _ = try await E2EWaits.until { try design.look(of: notes).frame.frameColor == DesignTests.frameLight }
            return look
        }
        run.check(
            "design.dark_colors",
            passed: dark.frame.frameColor == DesignTests.frameDark
                && dark.sidebar.selectedRowBackground == DesignTests.activeDark
                && dark.sidebar.selectedRowText == DesignTests.textDark && dark.frame.navigationDark,
            "frame=\(dark.frame.frameColor ?? "none") row=\(dark.sidebar.selectedRowBackground ?? "none")"
                + " text=\(dark.sidebar.selectedRowText ?? "none") navigation_dark=\(dark.frame.navigationDark)")

        try await run.step("the Blue Space", timeout: E2ETimeouts.firstLoad) {
            guard let work = window.spaceIDs[Fixture.work], let home = window.spaceIDs[Fixture.home] else {
                throw E2EError("the fixture has no \(Fixture.work) or \(Fixture.home) Space")
            }
            try edges.switchToSpace(work, besides: notes)
            _ = try await E2EWaits.until {
                try design.fixtureState(of: notes).activeTab.map(Fixture.workToday.contains) == true
                    && profiles.shownPage(besides: notes) != nil
            }
            guard let shown = try profiles.shownPage(besides: notes) else {
                throw E2EError("the \(Fixture.work) Space shows no page")
            }
            _ = try await shown.waitForLoad(after: 0)
            try await Fixture.waitForIcon(run, besides: notes)
            await Fixture.capture(run, notes, .window, "browsing-blue")
            try edges.switchToSpace(home, besides: notes)
            _ = try await E2EWaits.until { try design.fixtureState(of: notes).activeTab == Fixture.active }
        }

        if let top = run.app as? any E2ETopTabsApp {
            try await run.step("top tabs", timeout: E2ETimeouts.step) {
                try top.chooseUseTopTabs(in: notes)
                do {
                    _ = try await E2EWaits.until { try top.topTabs(of: notes).barShown }
                    await Fixture.capture(run, notes, .window, "top-tabs")
                } catch {
                    // Leave the sidebar layout and the saved setting as found, then fail the step.
                    if (try? top.topTabs(of: notes).barShown) == true { try? top.chooseUseTopTabs(in: notes) }
                    try? design.forgetWindowLayout()
                    throw error
                }
                try top.chooseUseTopTabs(in: notes)
                _ = try await E2EWaits.until { try !top.topTabs(of: notes).barShown }
                try design.forgetWindowLayout()
            }
        }

        try await run.step("command bar", timeout: E2ETimeouts.step) {
            let bar = try await DesignTests.openCommandBar(run, over: notes)
            await Fixture.capture(run, notes, .window, "command-bar")
            try bar.press(.escape)
            _ = try await E2EWaits.until { !bar.isShown }
        }

        try await run.step("narrow", timeout: E2ETimeouts.step) {
            try design.resizeWindow(of: notes, width: 640, height: 560)
            _ = try await E2EWaits.until {
                let look = try design.look(of: notes).frame
                return look.pageFrame.width < 400 && look.shadowFrame == look.pageFrame
            }
            await Fixture.capture(run, notes, .window, "narrow")
            try design.resizeWindow(of: notes, width: Fixture.width, height: Fixture.height)
        }

        let empty = try await run.step("empty Space", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: notes, profileID: edges.profileID(of: notes))
            try start.renameActiveSpace("Ideas", in: notes)
            _ = try await E2EWaits.until {
                let screen = try start.startScreen(of: notes)
                return screen.isShown && screen.hint.hasPrefix("Ideas")
            }
            await Fixture.capture(run, notes, .window, "empty-space")
            return try start.startScreen(of: notes)
        }

        let state = read.0
        let expected = [
            E2EDesignFixtureState.Space(
                name: Fixture.home, icon: Fixture.homeIcon, theme: nil,
                pinned: [Fixture.pinnedTab, "\(Fixture.folder)[\(Fixture.folderTabs.joined(separator: ","))]"],
                today: Fixture.today),
            E2EDesignFixtureState.Space(
                name: Fixture.work, icon: Fixture.workIcon, theme: DesignTests.blue, pinned: [],
                today: Fixture.workToday),
        ]
        let iconURL = Fixture.iconPrefix + "\(Fixture.active.lowercased()).png"
        run.check(
            "design.fixture",
            passed: state.spaces == expected && state.favorites == Fixture.favorites
                && state.activeTab == Fixture.active && state.activeTabHasIcon
                && read.1 == "\(iconURL) 200 image/png" && empty.greetingHour == Fixture.clockHour
                && empty.greeting == "Good morning",
            "spaces=\(state.spaces) favorites=\(state.favorites) active=\(state.activeTab ?? "none")"
                + " sidebar_icon=\(state.activeTabHasIcon) page_icon=\"\(read.1)\" hour=\(empty.greetingHour)"
                + " greeting=\"\(empty.greeting)\"")
    }
}
