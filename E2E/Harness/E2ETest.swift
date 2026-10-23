import Foundation

/// One e2e test: steps that drive the app through E2EApp and E2EPage, and the checks they record.
/// Tests live in E2E/Tests, one file per area.
@MainActor
protocol E2ETest {
    /// The name `--e2e=<name>` selects, also used for its check lines (for example `app.quit`). Names follow
    /// `<area>.<behavior>`; the area is the part before the first dot.
    var name: String { get }
    /// Every check the test records, in order. A test that stops early still counts the checks it never reached,
    /// as `FAIL <check>: not run`, so the run's total does not depend on how far tests got. Defaults to `[name]`.
    var checks: [String] { get }
    /// Tags `--e2e=<tag>` selects (for example `smoke`). Defaults to none.
    var tags: [String] { get }
    /// True for the one test that checks quitting with `E2ERun.expectQuit`. It runs last, and the runner leaves its
    /// windows open, so quitting is timed with only that test's window. Defaults to false.
    var quitsApp: Bool { get }
    /// True for a harness self test that ends its run on purpose (for example by getting the main thread stuck to
    /// prove the watchdog fires). Only a selection part that is exactly its name runs it: `all`, areas, globs and
    /// tags skip it, so normal runs never pay for it, and `--e2e=list` marks its line `by-name-only`. Defaults to
    /// false.
    var selectedByNameOnly: Bool { get }
    /// Changes to the engine's switches this test runs with (for example a measurement that needs Chromium's own
    /// background throttling back), or nil for the harness's switches. Switches are process wide, so the runner
    /// refuses a selection whose tests need different switches. Give it only to a `selectedByNameOnly` test, so
    /// `all`, areas, globs and tags never mix it with the others. Defaults to nil.
    var switchOverride: E2ESwitchOverride? { get }
    /// The seconds the whole test may take, steps and code between them. Defaults to `E2ERun.testTimeout`; only a
    /// `selectedByNameOnly` test (a long measurement) should need more.
    var timeLimit: TimeInterval { get }
    func run(_ run: E2ERun) async throws
}

extension E2ETest {
    var checks: [String] { [name] }
    var tags: [String] { [] }
    var quitsApp: Bool { false }
    var selectedByNameOnly: Bool { false }
    var switchOverride: E2ESwitchOverride? { nil }
    var timeLimit: TimeInterval { E2ERun.testTimeout }
    /// The part of the name before the first dot, which `--e2e=<area>` selects.
    var area: String { String(name.prefix { $0 != "." }) }
}

@MainActor
enum E2ETests {
    /// Every test, in the order `--e2e=all` runs them: each area's tests, as `E2EAreas.all` lists the areas.
    /// The test that checks quitting (it calls `E2ERun.expectQuit`) always runs last, whatever its place there.
    static let all: [any E2ETest] = E2EAreas.all.flatMap { $0 }

    /// The tests `selection` names, in the order of `all`. A selection is `all`, or a comma separated list of test
    /// names, areas (`tabs`), globs (`tabs.*`, `nav.?ack`) and tags (`smoke`). A test with `selectedByNameOnly`
    /// matches only its exact name. Throws for a part that matches nothing, listing the tests.
    static func select(_ selection: String, from tests: [any E2ETest] = all) throws -> [any E2ETest] {
        if selection == "all" { return tests.filter { !$0.selectedByNameOnly } }
        let parts = selection.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var chosen = Set<String>()
        for part in parts where !part.isEmpty {
            let matching = tests.filter { test in
                test.name == part
                    || (!test.selectedByNameOnly
                        && (test.area == part || test.tags.contains(part) || fnmatch(part, test.name, 0) == 0))
            }
            guard !matching.isEmpty else {
                let known = tests.filter { !$0.selectedByNameOnly }.map(\.name).joined(separator: ", ")
                throw E2EError(
                    "--e2e=\(selection): \(part) matches no test, area or tag; use all, list, or any of: \(known)")
            }
            chosen.formUnion(matching.map(\.name))
        }
        guard !chosen.isEmpty else { throw E2EError("--e2e=\(selection) selects no test") }
        return tests.filter { chosen.contains($0.name) }
    }

    /// The engine switches for running `tests` in one app: `base` changed by their `switchOverride`. Throws when two
    /// of them need different switches, since switches cannot change once the engine has started.
    static func switches(for tests: [any E2ETest], base: [String: String]) throws -> [String: String] {
        var chosen: (test: String, switches: [String: String])?
        for test in tests {
            let switches = test.switchOverride?.applied(to: base) ?? base
            if let chosen, chosen.switches != switches {
                throw E2EError(
                    "\(chosen.test) and \(test.name) need different engine switches, so they cannot run in one app; "
                        + "select them in separate runs")
            }
            if chosen == nil { chosen = (test.name, switches) }
        }
        return chosen?.switches ?? base
    }

    /// Throws when two tests share a name or a check, which would make their lines ambiguous, or a test declares a
    /// check the runner records itself.
    static func checkUnique(_ tests: [any E2ETest] = all) throws {
        let reserved: Set<String> = [E2ERunner.isolationCheck, E2ERunner.chromiumErrorsCheck]
        var names = Set<String>()
        var checks = Set<String>()
        for test in tests {
            guard names.insert(test.name).inserted else { throw E2EError("two e2e tests are named \(test.name)") }
            for check in test.checks {
                guard !reserved.contains(check) else {
                    throw E2EError("\(test.name) declares the check \(check), which the runner records itself")
                }
                guard checks.insert(check).inserted else { throw E2EError("two e2e tests declare the check \(check)") }
            }
        }
    }
}

/// Switches a test removes from and adds to the harness's engine switches (`E2ETest.switchOverride`).
struct E2ESwitchOverride: Equatable {
    /// Harness switches to leave out, by name without dashes.
    var removing: Set<String> = []
    /// Switches to add or replace, by name without dashes, with their values ("" for none).
    var adding: [String: String] = [:]

    func applied(to base: [String: String]) -> [String: String] {
        var switches = base.filter { !removing.contains($0.key) }
        switches.merge(adding) { _, added in added }
        return switches
    }
}

/// Step timeouts shared by tests.
enum E2ETimeouts {
    /// The first load waits for Chromium's helpers to start, which parallel builds can slow down a lot.
    static let firstLoad: TimeInterval = 15
    static let step: TimeInterval = 5
}

/// Fixture page URLs. Files in E2E/Fixtures/<area>/ are served at `https://bow.test/<area>/`. Six paths need no
/// file: `_redirect/<path>` redirects to `<path>`, `_204/<anything>` answers 204 No Content, `_error/<anything>`
/// fails to load, `_hang/<anything>` never answers (a page loading it keeps loading until stopped),
/// `_slow/<name>` is a download named `<name>` that never finishes (`_slow/<bytes>/<name>` sends that many bytes,
/// slowly, then finishes), and `_held/<key>/<bytes>/<name>` is a download held until the test releases it
/// (E2EHeldDownloads.swift).
enum E2EFixture {
    static func url(_ path: String) -> URL {
        URL(string: "https://bow.test/\(path)")!
    }

    /// The same fixture at `https://other.bow.test/`, which serves the same files as another site.
    static func otherSiteURL(_ path: String) -> URL {
        URL(string: "https://other.bow.test/\(path)")!
    }
}

/// Waits and assertions shared by tests. Every wait gives up on its own shortly before the running step's limit,
/// with an error that names what it waited for and what it saw last, so a slow page fails its step with a reason.
@MainActor
enum E2EWaits {
    /// How much of the step's time a wait leaves for the rest of the step when it gives up.
    static let margin: TimeInterval = 0.5

    /// The seconds a wait may take: the time left in the running step less `margin`, capped by `limit`.
    static func budget(limit: TimeInterval = .infinity) -> TimeInterval {
        let left = E2ERun.stepDeadline.map { $0.timeIntervalSinceNow - margin } ?? E2ETimeouts.step
        return max(min(left, limit), 0.05)
    }

    /// Waits until `condition` holds, checking it every 20 ms, and returns whether it held; a condition still false
    /// when the wait's budget (or `limit`) runs out is checked once more and returns false, so the caller can report
    /// what it saw as a failed check. It is for app state the harness reads in Swift (AppKit views, the sidebar
    /// store); page state waits in the page with `until(_:_:limit:)`.
    @discardableResult
    static func until(limit: TimeInterval = .infinity, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(budget(limit: limit))
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try condition()
    }

    /// Reads `read` every 20 ms until its value satisfies `done`, and returns that value, or the value it reads last
    /// when the wait's budget (or `limit`) runs out, so the caller can report what it saw as a failed check.
    static func value<Value>(
        limit: TimeInterval = .infinity, _ read: () throws -> Value, until done: (Value) -> Bool
    ) async throws -> Value {
        let deadline = Date().addingTimeInterval(budget(limit: limit))
        while Date() < deadline {
            let value = try read()
            if done(value) { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try read()
    }

    /// Throws unless the page counts as visible and paints three animation frames within the wait's budget,
    /// which an off-screen window must still do.
    static func untilRendering(_ page: any E2EPage) async throws {
        let visibility = try await page.string("document.visibilityState")
        guard visibility == "visible" else { throw E2EError("document.visibilityState is \(visibility)") }
        let budget = Int(budget() * 1000)
        // Counts animation frames; a timer ends the wait when the page stops painting.
        let frames = try await page.evaluate(
            """
            new Promise(resolve => {
              let frames = 0;
              const timer = setTimeout(() => resolve(frames), \(budget));
              const tick = () => {
                if (++frames < 3) return requestAnimationFrame(tick);
                clearTimeout(timer);
                resolve(frames);
              };
              requestAnimationFrame(tick);
            })
            """
        )
        guard (frames as? Int) == 3 else {
            throw E2EError("the page painted \(frames ?? "no") of 3 animation frames in \(budget) ms")
        }
    }

    /// Waits until the JavaScript expression `condition` is truthy in the page and returns its value. It checks
    /// once per animation frame while the page is visible and every 50 ms while it is hidden (hidden pages paint
    /// no frames). A condition still false when the wait's budget (or `limit`) runs out throws, naming the
    /// condition and its last value; one that throws fails the step with its error.
    @discardableResult
    static func until(_ page: any E2EPage, _ condition: String, limit: TimeInterval = .infinity) async throws -> Any? {
        let budget = Int(budget(limit: limit) * 1000)
        let result = try await page.evaluate(
            """
            new Promise((resolve, reject) => {
              const deadline = performance.now() + \(budget);
              const check = () => {
                let value;
                try {
                  value = (\(condition));
                } catch (error) {
                  return reject(error);
                }
                if (value) return resolve({ value });
                if (performance.now() >= deadline) return resolve({ timedOut: true, last: String(value) });
                if (document.visibilityState === "visible") requestAnimationFrame(check);
                else setTimeout(check, 50);
              };
              check();
            })
            """
        )
        guard let outcome = result as? [String: Any] else {
            throw E2EError("waiting for \(condition) returned nothing")
        }
        if outcome["timedOut"] as? Bool == true {
            throw E2EError("\(condition) was still \(outcome["last"] ?? "false") after \(budget) ms")
        }
        return outcome["value"]
    }

    /// The page's `document.visibilityState` once it reads `state`, or as it reads when the wait's budget (or
    /// `limit`) runs out, so a wrong state can be reported as a failed check rather than a timeout.
    static func visibility(of page: any E2EPage, becoming state: String, limit: TimeInterval = .infinity)
        async throws -> String
    {
        let budget = Int(budget(limit: limit) * 1000)
        return try await page.string(
            """
            new Promise(resolve => {
              if (document.visibilityState === "\(state)") return resolve(document.visibilityState);
              const timer = setTimeout(() => resolve(document.visibilityState), \(budget));
              document.addEventListener("visibilitychange", () => {
                if (document.visibilityState !== "\(state)") return;
                clearTimeout(timer);
                resolve(document.visibilityState);
              });
            })
            """
        )
    }
}
