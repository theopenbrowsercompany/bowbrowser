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
    func run(_ run: E2ERun) async throws
}

extension E2ETest {
    var checks: [String] { [name] }
    var tags: [String] { [] }
    var quitsApp: Bool { false }
    /// The part of the name before the first dot, which `--e2e=<area>` selects.
    var area: String { String(name.prefix { $0 != "." }) }
}

@MainActor
enum E2ETests {
    /// Every test, in the order `--e2e=all` runs them. Add each area's tests here.
    /// The test that checks quitting (it calls `E2ERun.expectQuit`) always runs last, whatever its place here.
    static let all: [any E2ETest] =
        AppTests.all + SandboxTests.all + InputTests.all + TabsTests.all + ProfilesTests.all + NavigationTests.all
        + FindTests.all
        + PermissionsTests.all
        + SidebarViewTests.all

    /// The tests `selection` names, in the order of `all`. A selection is `all`, or a comma separated list of test
    /// names, areas (`tabs`), globs (`tabs.*`, `nav.?ack`) and tags (`smoke`). Throws for a part that matches
    /// nothing, listing the tests.
    static func select(_ selection: String, from tests: [any E2ETest] = all) throws -> [any E2ETest] {
        if selection == "all" { return tests }
        let parts = selection.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var chosen = Set<String>()
        for part in parts where !part.isEmpty {
            let matching = tests.filter { test in
                test.name == part || test.area == part || test.tags.contains(part)
                    || fnmatch(part, test.name, 0) == 0
            }
            guard !matching.isEmpty else {
                let known = tests.map(\.name).joined(separator: ", ")
                throw E2EError(
                    "--e2e=\(selection): \(part) matches no test, area or tag; use all, list, or any of: \(known)")
            }
            chosen.formUnion(matching.map(\.name))
        }
        guard !chosen.isEmpty else { throw E2EError("--e2e=\(selection) selects no test") }
        return tests.filter { chosen.contains($0.name) }
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

/// Step timeouts shared by tests.
enum E2ETimeouts {
    /// The first load waits for Chromium's helpers to start, which parallel builds can slow down a lot.
    static let firstLoad: TimeInterval = 15
    static let step: TimeInterval = 5
}

/// Fixture page URLs. Files in E2E/Fixtures/<area>/ are served at `https://bow.test/<area>/`. Four paths need no
/// file: `_redirect/<path>` redirects to `<path>`, `_204/<anything>` answers 204 No Content, `_error/<anything>`
/// fails to load, and `_hang/<anything>` never answers (a page loading it keeps loading until stopped).
enum E2EFixture {
    static func url(_ path: String) -> URL {
        URL(string: "https://bow.test/\(path)")!
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
