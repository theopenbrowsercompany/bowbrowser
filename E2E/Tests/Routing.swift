import BowCore
import Foundation

/// Air Traffic Control: links from other apps follow the routing rules (by address and by source app) into a Space, a
/// profile or Little Arc, each created where it belongs before its first request; a helper process counts as its app;
/// the rule editor lists the rules and the app the last link came from; the rules survive a reload. Fixtures in
/// E2E/Fixtures/routing/.
@MainActor
enum RoutingAreaTests {
    static let all: [any E2ETest] = [
        E2ERoutingRulesTest(), E2ERoutingHelperTest(), E2ERoutingFirstRequestTest(), E2ERoutingEditorTest(),
        E2ERoutingEditorEditTest(), E2ERoutingPersistTest(),
    ]

    static let slack = "com.tinyspeck.slackmacgap"

    static func url(_ name: String, _ extra: String = "") -> URL {
        E2EFixture.url("routing/page.html?name=\(name)\(extra)")
    }

    static func app(_ run: E2ERun) throws -> any E2ERoutingApp & E2EStoreSeedApp & E2ELinksApp & E2ELittleArcApp {
        guard let app = run.app as? any E2ERoutingApp & E2EStoreSeedApp & E2ELinksApp & E2ELittleArcApp else {
            throw E2EError("the app has no Air Traffic Control")
        }
        return app
    }

    /// The seed every routing test starts from: Home (on screen, the test's profile), Work and Personal, each on a new
    /// profile of its own, with the profile IDs.
    static func seed(_ app: any E2EStoreSeedApp, active: String = "Home", workTab: URL? = nil) throws -> (
        seed: E2ESeed, work: String, personal: String
    ) {
        let base = try app.testProfileID()
        let work = base + "-work"
        let personal = base + "-personal"
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace("Home", today: [.tab("home", url: url("home"))]),
                E2ESeedSpace(
                    "Work", profile: .new(E2EProfile(id: work, isPersistent: false)),
                    today: workTab.map { [.tab("work", url: $0)] } ?? []),
                E2ESeedSpace("Personal", profile: .new(E2EProfile(id: personal, isPersistent: false))),
            ],
            activeSpace: active)
        return (seed, work, personal)
    }

    /// Opens the seeded window and the app's link intake (an e2e run keeps every link until a test asks).
    static func openWindow(_ run: E2ERun, _ app: any E2EStoreSeedApp & E2ELinksApp, seed: E2ESeed) async throws
        -> E2ESeededWindow
    {
        try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            let kept = try app.openKeptLinks()
            guard kept.isEmpty else { throw E2EError("\(kept.count) kept links opened") }
            return window
        }
    }

    /// The rules of the e2e example: an address with github.com opens in Space Work, a link from Slack in profile
    /// Personal, anything else in Little Arc.
    static func exampleTable(workSpace: String, personalProfile: String) -> RoutingTable {
        RoutingTable(
            rules: [
                RoutingRule(urlPattern: URLPattern(.contains, "github.com"), destination: .space(id: workSpace)),
                RoutingRule(sourceApp: slack, destination: .profile(id: personalProfile)),
            ],
            defaultDestination: .littleArc)
    }

    /// Waits for `link`'s page to load, or says why it cannot.
    static func load(_ link: E2ERoutedLink) async throws {
        guard let page = link.page else { throw E2EError("the link opened no page") }
        _ = try await page.waitForLoad(after: 0)
    }
}

/// With the e2e example rules and Little Arc on: a github.com link from Bow opens a new tab in Space Work (in Work's
/// profile), a link from Slack in Personal's Space, and a link from another app (Mail) that no rule matches in
/// Little Arc, the default.
struct E2ERoutingRulesTest: E2ETest {
    let name = "routing"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let app = try RoutingAreaTests.app(run)
        try app.setLittleArcSetting(true)
        let (seed, work, personal) = try RoutingAreaTests.seed(app)
        let window = try await RoutingAreaTests.openWindow(run, app, seed: seed)
        guard let workSpace = window.spaceIDs["Work"] else { throw E2EError("the seed has no Work") }
        try app.setRoutingTable(RoutingAreaTests.exampleTable(workSpace: workSpace, personalProfile: personal))

        func deliver(_ step: String, _ url: URL, from source: String?) async throws -> E2ERoutedLink {
            try await run.step(step, timeout: E2ETimeouts.firstLoad) {
                try app.sendLinks(as: source)
                let link = try app.deliverRoutedLink(url)
                try await RoutingAreaTests.load(link)
                return link
            }
        }
        let github = try await deliver(
            "deliver a github.com link", RoutingAreaTests.url("github", "&site=github.com/bow"), from: nil)
        let slack = try await deliver(
            "deliver a link from Slack", RoutingAreaTests.url("chat"), from: RoutingAreaTests.slack)
        let other = try await deliver("deliver a link from Mail", RoutingAreaTests.url("mail"), from: "com.apple.mail")

        var problems: [String] = []
        if github.place == "work", github.profileID != work {
            problems.append("github profile \(github.profileID ?? "none")")
        }
        if slack.place == "personal", slack.profileID != personal {
            problems.append("slack profile \(slack.profileID ?? "none")")
        }
        let littleArcWindows = try app.littleArcWindows().count
        if other.littleArc, littleArcWindows != 1 { problems.append("\(littleArcWindows) Little Arc windows") }
        let detail = "github.com->\(github.place) slack->\(slack.place) fallback=\(other.place)"
        run.check(
            name,
            passed: github.place == "work" && slack.place == "personal" && other.place == "little-arc"
                && problems.isEmpty,
            problems.isEmpty ? detail : detail + " " + problems.joined(separator: ", "))
    }
}

/// A link a helper process of Bow sends (Chromium's renderer, inside Bow.app) counts as Bow's: a rule on Bow's bundle
/// identifier routes it into Space Work.
struct E2ERoutingHelperTest: E2ETest {
    let name = "routing.helper"

    func run(_ run: E2ERun) async throws {
        let app = try RoutingAreaTests.app(run)
        let (seed, _, _) = try RoutingAreaTests.seed(app)
        let window = try await RoutingAreaTests.openWindow(run, app, seed: seed)
        guard let workSpace = window.spaceIDs["Work"] else { throw E2EError("the seed has no Work") }
        let bow = app.routingAppBundleID
        try app.setRoutingTable(
            RoutingTable(
                rules: [RoutingRule(sourceApp: bow, destination: .space(id: workSpace))],
                defaultDestination: .mostRecentWindow))
        let result = try await run.step("deliver a link from a helper", timeout: E2ETimeouts.firstLoad) {
            guard let result = try app.deliverLinkFromHelper(RoutingAreaTests.url("helper")) else {
                throw E2EError("Bow runs no helper process")
            }
            try await RoutingAreaTests.load(result.opened)
            return result
        }
        let isHelper = !bow.isEmpty && result.helper != bow
        run.check(
            name, passed: isHelper && result.opened.place == "work",
            isHelper ? "helper->bow routed=\(result.opened.place)" : "helper=\(result.helper) bow=\(bow)")
    }
}

/// The routed tab is created in its Space's profile and its first request goes out there: with Work's profile marked
/// (a Work tab stored a mark in its localStorage) and Home on screen, a github.com link opens exactly one new page,
/// created in Work's profile, which reads Work's mark when it starts and loaded once (it never loaded elsewhere and
/// moved).
struct E2ERoutingFirstRequestTest: E2ETest {
    let name = "routing.first_request"

    func run(_ run: E2ERun) async throws {
        let app = try RoutingAreaTests.app(run)
        guard let menu = run.app as? any E2EMenuApp else { throw E2EError("the app has no menu") }
        let (seed, work, personal) = try RoutingAreaTests.seed(
            app, active: "Work", workTab: RoutingAreaTests.url("work", "&mark=work"))
        let window = try await RoutingAreaTests.openWindow(run, app, seed: seed)
        guard let workSpace = window.spaceIDs["Work"] else { throw E2EError("the seed has no Work") }
        try await run.step("show Home", timeout: E2ETimeouts.step) {
            try menu.chooseMenuItem(key: "1", modifiers: .control, in: window.page)
            let state = try app.browserWindowState(of: window.page)
            guard state.spaceTitle == "Home" else { throw E2EError("the window shows \(state.spaceTitle)") }
        }
        try app.setRoutingTable(RoutingAreaTests.exampleTable(workSpace: workSpace, personalProfile: personal))
        let before = app.routingOpenBrowsers
        let link = try await run.step("deliver a github.com link", timeout: E2ETimeouts.firstLoad) {
            let link = try app.deliverRoutedLink(RoutingAreaTests.url("first", "&site=github.com"))
            try await RoutingAreaTests.load(link)
            return link
        }
        guard let page = link.page else { throw E2EError("the link opened no page") }
        let mark = try await page.string("String(window.bowMarkAtLoad)")
        let loads = try await page.string("sessionStorage.getItem('bowLoads')")
        let created = app.routingOpenBrowsers - before
        var problems: [String] = []
        if link.place != "work" { problems.append("opened in \(link.place)") }
        if link.profileID != work { problems.append("profile=\(link.profileID ?? "none")") }
        if mark != "work" { problems.append("mark=\(mark)") }
        if loads != "1" || page.finishedLoads != 1 { problems.append("loads=\(loads)/\(page.finishedLoads)") }
        if created != 1 { problems.append("pages_created=\(created)") }
        run.check(
            name, passed: problems.isEmpty,
            problems.isEmpty ? "profile=work pages_created=1 loads=1" : problems.joined(separator: ", "))
    }
}

/// Bow > Air Traffic Control… opens the editor off screen: it lists the rules in order (match, text, app,
/// destination) and the default, and while it is open a link from Slack arrives and its line names Slack's bundle
/// identifier. Move Down reorders the rules and saves the new order; the close button closes it.
struct E2ERoutingEditorTest: E2ETest {
    let name = "routing.editor"

    func run(_ run: E2ERun) async throws {
        let app = try RoutingAreaTests.app(run)
        let (seed, _, personal) = try RoutingAreaTests.seed(app)
        let window = try await RoutingAreaTests.openWindow(run, app, seed: seed)
        guard let workSpace = window.spaceIDs["Work"] else { throw E2EError("the seed has no Work") }
        let table = RoutingAreaTests.exampleTable(workSpace: workSpace, personalProfile: personal)
        try app.setRoutingTable(table)
        let opened = try await run.step("open the editor", timeout: E2ETimeouts.step) {
            try app.openRoutingEditor(from: window.page)
            guard let state = try app.routingEditor() else { throw E2EError("the editor did not open") }
            return state
        }
        let link = try await run.step("deliver a link from Slack", timeout: E2ETimeouts.firstLoad) {
            try app.sendLinks(as: RoutingAreaTests.slack)
            let link = try app.deliverRoutedLink(RoutingAreaTests.url("editor"))
            try await RoutingAreaTests.load(link)
            return link
        }
        let afterLink = try app.routingEditor()
        try app.moveRuleDownInEditor(row: 0)
        let moved = try app.routingEditor()
        let saved = try app.routingTable().rules.map(\.id)
        try app.closeRoutingEditor()
        let closed = try app.routingEditor() == nil

        let expectedRows = [
            ["contains", "github.com", "", "Space: Work"],
            ["is any address", "", RoutingAreaTests.slack, "Profile: \(personal)"],
        ]
        var problems: [String] = []
        if opened.rows != expectedRows { problems.append("rows=\(opened.rows)") }
        if opened.defaultTitle != "Little Arc" { problems.append("default=\(opened.defaultTitle)") }
        if opened.intrudes { problems.append("on screen or key at \(opened.frame) key=\(opened.isKey)") }
        let line = afterLink?.lastSourceLine ?? "none"
        let sourceShown =
            line.hasPrefix("Last link came from:") && line.contains("(\(RoutingAreaTests.slack))")
            || line == "Last link came from: \(RoutingAreaTests.slack)"
        if !sourceShown { problems.append("line=\"\(line)\"") }
        if link.place != "personal" { problems.append("link opened in \(link.place)") }
        if moved?.rows != Array(expectedRows.reversed()) { problems.append("moved=\(moved?.rows ?? [])") }
        if saved != table.rules.reversed().map(\.id) { problems.append("saved order differs") }
        if !closed { problems.append("still open") }
        run.check(
            name, passed: problems.isEmpty,
            problems.isEmpty ? "rules=2 source=slack reorder=saved" : problems.joined(separator: ", "))
    }
}

/// Typing in the rule table saves when the edit ends, with no Return: text typed in a rule's Text cell is saved once
/// focus moves to the destination pop-up, and text typed in another rule's app cell is saved when the window closes.
/// The cells are driven through the real field editor.
struct E2ERoutingEditorEditTest: E2ETest {
    let name = "routing.editor_edit"

    func run(_ run: E2ERun) async throws {
        let app = try RoutingAreaTests.app(run)
        let (seed, _, personal) = try RoutingAreaTests.seed(app)
        let window = try await RoutingAreaTests.openWindow(run, app, seed: seed)
        guard let workSpace = window.spaceIDs["Work"] else { throw E2EError("the seed has no Work") }
        try app.setRoutingTable(RoutingAreaTests.exampleTable(workSpace: workSpace, personalProfile: personal))
        try await run.step("open the editor", timeout: E2ETimeouts.step) {
            try app.openRoutingEditor(from: window.page)
            guard try app.routingEditor() != nil else { throw E2EError("the editor did not open") }
        }
        try app.typeInEditorCell(row: 0, column: 1, text: "gitlab.com")
        try app.focusEditorDestination(row: 0)
        let afterFocus = try app.routingTable().rules
        try app.typeInEditorCell(row: 1, column: 2, text: "com.example.typed")
        try app.closeRoutingEditor()
        let afterClose = try app.routingTable().rules

        var problems: [String] = []
        if afterFocus.first?.urlPattern?.text != "gitlab.com" {
            problems.append("after focus text=\(afterFocus.first?.urlPattern?.text ?? "none")")
        }
        if afterClose.first?.urlPattern?.text != "gitlab.com" { problems.append("text lost on close") }
        if afterClose.last?.sourceApp != "com.example.typed" {
            problems.append("after close app=\(afterClose.last?.sourceApp ?? "none")")
        }
        run.check(
            name, passed: problems.isEmpty,
            problems.isEmpty ? "text saved on focus change, app saved on close" : problems.joined(separator: ", "))
    }
}

/// Rules saved through the app (address and source app conditions, every kind of destination, a default and a
/// "no source" fallback) come back the same from a new Air Traffic Control service on the same folder, as at the
/// next launch.
struct E2ERoutingPersistTest: E2ETest {
    let name = "routing.persist"

    func run(_ run: E2ERun) async throws {
        let app = try RoutingAreaTests.app(run)
        let table = RoutingTable(
            rules: [
                RoutingRule(
                    urlPattern: URLPattern(.matches, #"^https://[a-z]+\.example\.com/"#), destination: .littleArc),
                RoutingRule(
                    urlPattern: URLPattern(.contains, "docs"), sourceApp: "com.apple.mail",
                    destination: .space(id: "space-1")),
                RoutingRule(sourceApp: RoutingAreaTests.slack, destination: .profile(id: "profile-1")),
            ],
            defaultDestination: .mostRecentWindow, noSourceDestination: .littleArc)
        try app.setRoutingTable(table)
        let reloaded = try app.reloadedRoutingTable()
        let same = reloaded == table
        run.check(
            name, passed: same,
            same ? "rules=3 default=most-recent-window no_source=little-arc" : "reloaded=\(reloaded)")
    }
}
