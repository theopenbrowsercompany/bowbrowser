import Foundation

/// Tests of a tab's main frame navigation events and policy. Fixtures in E2E/Fixtures/navigation/, plus the
/// fixture server's `/_redirect/`, `/_error/` and `/_204/` paths.
@MainActor
enum NavigationTests {
    static let all: [any E2ETest] = [NavigationEventsTest(), NavigationPopupTest()]
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
