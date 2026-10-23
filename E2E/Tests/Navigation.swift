import Foundation

/// Tests of a tab's main frame navigation events and policy. Fixtures in E2E/Fixtures/navigation/, plus the
/// fixture server's `/_redirect/`, `/_error/` and `/_204/` paths.
@MainActor
enum NavigationTests {
    static let all: [any E2ETest] = [NavigationEventsTest(), NavigationPopupTest(), NavigationHistoryTest()]
}

/// Drives the window's back, forward, reload and stop controls the way a person does: the toolbar buttons and the
/// menu shortcuts (Cmd+[, Cmd+], Cmd+R, Cmd+.). Checks that back and forward land on the right pages, that the
/// buttons are disabled when the tab cannot go back or forward, that reload loads a new document, and that a load
/// shows stop in place of reload and can be stopped.
struct NavigationHistoryTest: E2ETest {
    let name = "nav.history"

    /// How long a toolbar state may take to follow the engine's state push before the check fails.
    static let settle: TimeInterval = 3

    func run(_ run: E2ERun) async throws {
        let pageA = E2EFixture.url("navigation/a.html")
        let pageB = E2EFixture.url("navigation/b.html")
        let slow = E2EFixture.url("navigation/slow.html")
        let app = run.app

        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await app.openWindow(at: pageA)
        }
        try await run.step("load page A", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("page A loaded with status \(status)") }
        }
        /// Loads one page with `navigate` and returns its title.
        func navigate(_ navigate: () throws -> Void) async throws -> String {
            let loads = page.finishedLoads
            try navigate()
            _ = try await page.waitForLoad(after: loads)
            return try await page.string("document.title")
        }

        var problems: [String] = []
        // Back off, forward off, reload on: a fresh tab has no history.
        let fresh = try await run.step("check a fresh tab", timeout: E2ETimeouts.step) {
            try await Self.waitForButtons(app, page, back: false, forward: false)
        }
        if let fresh { problems.append("fresh tab: \(fresh)") }
        try await run.step("load page B", timeout: E2ETimeouts.step) {
            _ = try await navigate { page.load(pageB) }
            if let wrong = try await Self.waitForButtons(app, page, back: true, forward: false) {
                problems.append("after loading B: \(wrong)")
            }
        }
        let back = try await run.step("go back with the toolbar", timeout: E2ETimeouts.step) {
            let title = try await navigate { try app.click(.back, in: page) }
            if let wrong = try await Self.waitForButtons(app, page, back: false, forward: true) {
                problems.append("after back: \(wrong)")
            }
            return title
        }
        let forward = try await run.step("go forward with the toolbar", timeout: E2ETimeouts.step) {
            let title = try await navigate { try app.click(.forward, in: page) }
            if let wrong = try await Self.waitForButtons(app, page, back: true, forward: false) {
                problems.append("after forward: \(wrong)")
            }
            return title
        }
        let passed = back == "A" && forward == "B" && problems.isEmpty
        run.check(
            name, passed: passed,
            "back=\(back) forward=\(forward)" + (problems.isEmpty ? "" : " " + problems.joined(separator: "; ")))

        let shortcuts = try await run.step("go back and forward with shortcuts", timeout: E2ETimeouts.step) {
            let back = try await navigate { try app.press(.back, in: page) }
            _ = try await Self.waitForButtons(app, page, back: false, forward: true)
            let forward = try await navigate { try app.press(.forward, in: page) }
            _ = try await Self.waitForButtons(app, page, back: true, forward: false)
            // With nothing ahead, the menu item is disabled like the button.
            let refused = (try? app.press(.forward, in: page)) == nil
            return (back: back, forward: forward, refused: refused)
        }
        run.check(
            "nav.shortcuts", passed: shortcuts.back == "A" && shortcuts.forward == "B" && shortcuts.refused,
            "back=\(shortcuts.back) forward=\(shortcuts.forward) disabled-forward=\(shortcuts.refused ? "refused" : "ran")")

        // A reload loads a new document: a mark the page held is gone afterwards.
        func reload(_ reload: () throws -> Void) async throws -> String {
            _ = try await page.evaluate("window.bowMark = 'kept'")
            let title = try await navigate(reload)
            let mark = try await page.evaluate("window.bowMark")
            return mark == nil && title == "B" ? "reloaded" : "title=\(title) mark=\(mark ?? "none")"
        }
        let reloads = try await run.step("reload", timeout: E2ETimeouts.step) {
            (toolbar: try await reload { try app.click(.reload, in: page) },
             shortcut: try await reload { try app.press(.reload, in: page) })
        }
        run.check(
            "nav.reload", passed: reloads.toolbar == "reloaded" && reloads.shortcut == "reloaded",
            "toolbar=\(reloads.toolbar) shortcut=\(reloads.shortcut)")

        // The slow page never finishes on its own, so the reload button shows stop until it is stopped.
        let stops = try await run.step("stop loads", timeout: E2ETimeouts.step * 3) {
            // Stopped once the page has committed, so the page shown, and so reloaded, is the slow one.
            var commits = Self.commits(of: slow, in: page)
            page.load(slow)
            let loading = try await Self.waitForReload(app, page, label: "Stop")
            try await Self.waitForCommit(of: slow, after: commits, in: page)
            try app.click(.reload, in: page)
            let stopped = try await Self.waitForReload(app, page, label: "Reload")
            commits = Self.commits(of: slow, in: page)
            try app.click(.reload, in: page)
            let reloading = try await Self.waitForReload(app, page, label: "Stop")
            try await Self.waitForCommit(of: slow, after: commits, in: page)
            try app.press(.stop, in: page)
            let stoppedAgain = try await Self.waitForReload(app, page, label: "Reload")
            let refused = (try? app.press(.stop, in: page)) == nil
            return [
                "loading=\(loading)", "toolbar-stop=\(stopped)", "reloading=\(reloading)",
                "shortcut-stop=\(stoppedAgain)", "idle-stop=\(refused ? "refused" : "ran")",
            ]
        }
        let expectedStops = [
            "loading=Stop(on)", "toolbar-stop=Reload(on)", "reloading=Stop(on)", "shortcut-stop=Reload(on)",
            "idle-stop=refused",
        ]
        run.check("nav.stop", passed: stops == expectedStops, stops.joined(separator: " "))
    }

    /// Waits until the back and forward buttons are enabled as expected and the reload button reads Reload and is
    /// enabled. Returns nil once they are, or what they show after `settle` seconds.
    private static func waitForButtons(
        _ app: any E2EApp, _ page: any E2EPage, back: Bool, forward: Bool
    ) async throws -> String? {
        let expected = [
            E2EToolbarButtonState(isEnabled: back, label: "Back"),
            E2EToolbarButtonState(isEnabled: forward, label: "Forward"),
            E2EToolbarButtonState(isEnabled: true, label: "Reload"),
        ]
        let deadline = Date().addingTimeInterval(settle)
        while true {
            let shown = try [E2EToolbarButton.back, .forward, .reload].map { try app.toolbarButton($0, in: page) }
            if shown == expected { return nil }
            if Date() > deadline { return "buttons=\(shown) expected=\(expected)" }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func commits(of url: URL, in page: any E2EPage) -> Int {
        page.navigationEvents.filter { $0.kind == .commit && $0.url == url }.count
    }

    /// Waits until `url` has committed more than `commits` times; the step's timeout bounds the wait.
    private static func waitForCommit(of url: URL, after commits: Int, in page: any E2EPage) async throws {
        while Self.commits(of: url, in: page) <= commits {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until the reload button reads `label` and returns what it shows then, or after `settle` seconds.
    private static func waitForReload(_ app: any E2EApp, _ page: any E2EPage, label: String) async throws -> String {
        let deadline = Date().addingTimeInterval(settle)
        while true {
            let shown = try app.toolbarButton(.reload, in: page)
            if shown.label == label || Date() > deadline { return shown.description }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Opens pages from a fixture the way sign in flows do, a sized popup and a plain `window.open(url)`, and checks
/// that each new page can still post a message back through `window.opener`. The run keeps popups off screen.
struct NavigationPopupTest: E2ETest {
    let name = "nav.popup"

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("navigation/opener.html"))
        }
        try await run.step("load opener", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the opener loaded with status \(status)") }
        }
        let expected = ["opened?via=popup", "opened?via=open"]
        let messages = try await run.step("open popups", timeout: E2ETimeouts.firstLoad) {
            for open in [
                "window.open('child.html?via=popup', 'child', 'width=480,height=360')",
                "window.open('child.html?via=open')",
            ] {
                // As if from a click: pages open popups from user actions.
                _ = try await page.devTools(
                    "Runtime.evaluate", ["expression": "void \(open)", "userGesture": true])
            }
            // The messages the children posted, once both have arrived or after five seconds.
            return try await page.string(
                """
                new Promise(resolve => {
                  const done = () => window.bowMessages.length >= \(expected.count);
                  const finish = () => resolve(window.bowMessages.slice().sort().join(","));
                  if (done()) return finish();
                  const timer = setTimeout(finish, 5000);
                  window.addEventListener("message", () => {
                    if (!done()) return;
                    clearTimeout(timer);
                    finish();
                  });
                })
                """
            )
        }
        let passed = messages == expected.sorted().joined(separator: ",")
        run.check(name, passed: passed, passed ? "opener=kept" : "messages=\"\(messages)\" expected=\(expected)")
    }
}

/// Loads pages in one tab and checks the navigation events it reports, in order: a plain load (start, commit,
/// finish), a server redirect (start, redirect, commit, finish), a failed load (start, fail, and nothing for the
/// error page Chromium shows), a load the navigation policy cancels (no events, and the page stays), going back
/// (start, commit, finish), and a 204 answer (start, then fail as aborted, and the page stays).
struct NavigationEventsTest: E2ETest {
    let name = "nav.events"

    func run(_ run: E2ERun) async throws {
        let start = E2EFixture.url("navigation/start.html")
        let target = E2EFixture.url("navigation/target.html")
        let redirect = E2EFixture.url("_redirect/navigation/target.html")
        let broken = E2EFixture.url("_error/navigation")
        let blocked = E2EFixture.url("navigation/blocked.html")
        let noContent = E2EFixture.url("_204/navigation")

        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: start)
        }
        try await run.step("load start page", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the start page loaded with status \(status)") }
        }
        Self.check(
            run, name, page.navigationEvents,
            expected: [
                .init(kind: .start, url: start), .init(kind: .commit, url: start),
                .init(kind: .finish, url: start, code: 200),
            ])

        var first = page.navigationEvents.count
        try await run.step("load through a redirect", timeout: E2ETimeouts.step) {
            let loads = page.finishedLoads
            page.load(redirect)
            let status = try await page.waitForLoad(after: loads)
            guard status == 200 else { throw E2EError("the redirect target loaded with status \(status)") }
        }
        Self.check(
            run, "nav.redirect", Array(page.navigationEvents[first...]),
            expected: [
                .init(kind: .start, url: redirect), .init(kind: .redirect, url: target),
                .init(kind: .commit, url: target), .init(kind: .finish, url: target, code: 200),
            ])

        first = page.navigationEvents.count
        try await run.step("load a page that fails", timeout: E2ETimeouts.step) {
            let loads = page.finishedLoads
            page.load(broken)
            // The load is expected to fail; the events checked below say how.
            let status = try? await page.waitForLoad(after: loads)
            if let status { throw E2EError("the failing page loaded with status \(status)") }
        }
        let failEvents = page.navigationEvents.count

        var policyAsked: [URL] = []
        try await run.step("cancel a load by policy", timeout: E2ETimeouts.step) {
            page.navigationPolicy = { url in
                policyAsked.append(url)
                return url != blocked
            }
            page.load(blocked)
            // The policy answers synchronously when the navigation starts; loading again before then would
            // replace the blocked navigation instead of letting the policy cancel it.
            while !policyAsked.contains(blocked) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let loads = page.finishedLoads
            page.load(target)
            let status = try await page.waitForLoad(after: loads)
            guard status == 200 else { throw E2EError("the page after the cancel loaded with status \(status)") }
        }
        // Anything the error page reported would sit between the failure and the next load's start.
        Self.check(
            run, "nav.fail", Array(page.navigationEvents[first..<min(failEvents + 1, page.navigationEvents.count)]),
            expected: [
                .init(kind: .start, url: broken), .init(kind: .fail, url: broken, code: -102),
                .init(kind: .start, url: target),
            ])
        try await run.step("check the cancel", timeout: E2ETimeouts.step) {
            let title = try await page.string("document.title")
            let events = Array(page.navigationEvents[failEvents...])
            let expected: [E2ENavigationEvent] = [
                .init(kind: .start, url: target), .init(kind: .commit, url: target),
                .init(kind: .finish, url: target, code: 200),
            ]
            let passed = events == expected && title == "Navigation target"
            run.check(
                "nav.policy", passed: passed,
                passed
                    ? "canceled=\(blocked.path) asked=\(policyAsked.count)"
                    : "title=\"\(title)\" events=\(events) expected=\(expected)")
        }

        page.navigationPolicy = nil
        try await run.step("load the start page again", timeout: E2ETimeouts.step) {
            let loads = page.finishedLoads
            page.load(start)
            let status = try await page.waitForLoad(after: loads)
            guard status == 200 else { throw E2EError("the start page loaded with status \(status)") }
        }
        first = page.navigationEvents.count
        // Chromium reports a history navigation's HTTP status as 0, so the finish is compared without it.
        try await run.step("go back", timeout: E2ETimeouts.step) {
            let loads = page.finishedLoads
            _ = try await page.evaluate("history.back()")
            _ = try await page.waitForLoad(after: loads)
        }
        Self.check(
            run, "nav.back", page.navigationEvents[first...].map { E2ENavigationEvent(kind: $0.kind, url: $0.url) },
            expected: [
                .init(kind: .start, url: target), .init(kind: .commit, url: target), .init(kind: .finish, url: target),
            ])

        // A 204 answer leaves the page where it is, and the navigation still ends: it fails as aborted (-3).
        first = page.navigationEvents.count
        try await run.step("load a page with no content", timeout: E2ETimeouts.step) {
            let loads = page.finishedLoads
            page.load(noContent)
            let status = try? await page.waitForLoad(after: loads)
            if let status { throw E2EError("the 204 answer loaded with status \(status)") }
        }
        try await run.step("check the page stayed", timeout: E2ETimeouts.step) {
            let title = try await page.string("document.title")
            let events = Array(page.navigationEvents[first...])
            let expected: [E2ENavigationEvent] = [
                .init(kind: .start, url: noContent), .init(kind: .fail, url: noContent, code: -3),
            ]
            let passed = events == expected && title == "Navigation target"
            let order = events.map(\.kind.rawValue).joined(separator: ",")
            run.check(
                "nav.abort", passed: passed,
                passed ? "order=\(order) stayed=target" : "title=\"\(title)\" events=\(events) expected=\(expected)")
        }
    }

    /// Records a check that `events` are exactly `expected`, reporting their order.
    private static func check(
        _ run: E2ERun,
        _ name: String,
        _ events: [E2ENavigationEvent],
        expected: [E2ENavigationEvent]
    ) {
        let order = events.map(\.kind.rawValue).joined(separator: ",")
        let passed = events == expected
        run.check(name, passed: passed, passed ? "order=\(order)" : "events=\(events) expected=\(expected)")
    }
}
