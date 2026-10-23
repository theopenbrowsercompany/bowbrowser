import Foundation

/// Tests of collapsing every folder of a Space. Fixtures are the sidebar area's page (E2E/Fixtures/sidebar/).
@MainActor
enum CollapseTests {
    static let all: [any E2ETest] = [
        CollapseMenuTest(),
        CollapseCommandTest(),
    ]

    static func app(_ run: E2ERun) throws -> any E2ECollapseApp {
        guard let app = run.app as? any E2ECollapseApp else { throw E2EError("the app has no collapse command") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("sidebar/page.html?name=\(name)") }

    /// Tab A under Keep > Deep, Other > Sub > T1 beside it, and Third > T2 in today: five open folders, two of them
    /// above the active tab A.
    static func seed() -> E2ESeed {
        E2ESeed(spaces: [
            E2ESeedSpace(
                "Work",
                pinned: [
                    .folder("Keep", [.folder("Deep", [.tab("A", url: url("A"))])]),
                    .folder("Other", [.folder("Sub", [.tab("T1", url: url("T1"))])]),
                ],
                today: [.folder("Third", [.tab("T2", url: url("T2"))])])
        ])
    }

    static let opened =
        "favorites | pinned | >Keep | >>Deep | >>>A | >Other | >>Sub | >>>T1 | divider | today | >Third | >>T2"
    static let collapsed = "favorites | pinned | >Keep | >>Deep | >>>A | >Other | divider | today | >Third"

    /// The tabs among the outline's rows, which are the ones a person sees.
    static func visibleTabs(_ outline: String) -> String {
        outline.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).drop { $0 == ">" } }
            .filter { ["A", "T1", "T2"].contains(String($0)) }.joined(separator: ",")
    }

    static func open(_ run: E2ERun, _ app: any E2ECollapseApp) async throws -> E2ESeededWindow {
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed())
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let outline = try await run.step("read the seeded outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: window.page, until: opened)
        }
        guard outline == opened else { throw E2EError("the seeded outline is \(outline)") }
        return window
    }
}

/// View > Collapse All Folders folds all but the path to the active tab, and the result is saved.
struct CollapseMenuTest: E2ETest {
    let name = "collapse"
    let tags = ["smoke"]
    let checks = ["collapse", "collapse.saved"]

    func run(_ run: E2ERun) async throws {
        let app = try CollapseTests.app(run)
        let page = try await CollapseTests.open(run, app).page
        try await run.step("choose Collapse All Folders", timeout: E2ETimeouts.step) {
            try app.chooseCollapseAllFolders(in: page)
        }
        let outline = try await run.step("read the collapsed outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: page, until: CollapseTests.collapsed)
        }
        let count = try app.lastCollapsedCount(of: page)
        let visible = CollapseTests.visibleTabs(outline)
        run.check(
            "collapse", passed: outline == CollapseTests.collapsed && count == 3 && visible == "A",
            "collapsed=\(count) visible=\(visible)\(outline == CollapseTests.collapsed ? "" : " outline=\(outline)")")

        let relaunched = try await run.step("relaunch", timeout: E2ETimeouts.firstLoad) {
            try await app.relaunchSidebar(of: page)
        }
        let after = try await run.step("read the relaunched outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: relaunched.page, until: CollapseTests.collapsed)
        }
        run.check(
            "collapse.saved", passed: after == CollapseTests.collapsed,
            after == CollapseTests.collapsed ? "kept after relaunch" : after)
    }
}

/// The command bar offers Collapse All Folders for "collapse" and Enter runs it.
struct CollapseCommandTest: E2ETest {
    let name = "collapse.command"
    let checks = ["collapse.command"]

    func run(_ run: E2ERun) async throws {
        let app = try CollapseTests.app(run)
        let page = try await CollapseTests.open(run, app).page
        let rows = try await run.step("type collapse in the command bar", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "t", modifiers: .command, in: page)
            let bar = try app.commandBar(of: page)
            try bar.type("collapse")
            return try await bar.waitForResults()
        }
        let offered = rows.first.map { "\($0.kind):\($0.title)" } ?? "none"
        try await run.step("press Enter", timeout: E2ETimeouts.step) {
            try app.commandBar(of: page).press(.enter)
        }
        let outline = try await run.step("read the collapsed outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: page, until: CollapseTests.collapsed)
        }
        let passed = offered == "command:Collapse All Folders" && outline == CollapseTests.collapsed
        run.check(
            "collapse.command", passed: passed,
            passed ? "offered and run" : "offered=\(offered) outline=\(outline)")
    }
}
