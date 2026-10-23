import Foundation

/// One e2e test: steps that drive the app through E2EApp and E2EPage, and the checks they record.
/// Tests live in E2E/Tests, one file per area.
@MainActor
protocol E2ETest {
    /// The name `--e2e=<name>` selects, also used for its check lines (for example `app.quit`).
    var name: String { get }
    func run(_ run: E2ERun) async throws
}

@MainActor
enum E2ETests {
    /// Every test, in the order `--e2e=all` runs them. Add each area's tests here.
    static let all: [any E2ETest] =
        AppTests.all + SandboxTests.all + InputTests.all + TabsTests.all + ProfilesTests.all + NavigationTests.all
        + FindTests.all
        + PermissionsTests.all
        + SidebarTests.all
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

/// Waits and assertions shared by tests.
@MainActor
enum E2EWaits {
    /// Throws unless the page counts as visible and is painting frames, which an off-screen window must still do.
    static func untilRendering(_ page: any E2EPage) async throws {
        let visibility = try await page.string("document.visibilityState")
        guard visibility == "visible" else { throw E2EError("document.visibilityState is \(visibility)") }
        // Resolves after three animation frames; a page that does not paint never resolves and the step times out.
        let frames = try await page.evaluate(
            """
            new Promise(resolve => {
              let frames = 0;
              const tick = () => (++frames >= 3 ? resolve(frames) : requestAnimationFrame(tick));
              requestAnimationFrame(tick);
            })
            """
        )
        guard (frames as? Int) == 3 else { throw E2EError("requestAnimationFrame counted \(frames ?? "nothing")") }
    }

    /// Waits until the JavaScript expression `condition` is truthy in the page, checking it once per animation
    /// frame, and returns its value. It never sleeps: a condition that never holds runs into the step's timeout,
    /// and one that throws fails the step with its error.
    @discardableResult
    static func until(_ page: any E2EPage, _ condition: String) async throws -> Any? {
        try await page.evaluate(
            """
            new Promise((resolve, reject) => {
              const check = () => {
                try {
                  const value = (\(condition));
                  value ? resolve(value) : requestAnimationFrame(check);
                } catch (error) {
                  reject(error);
                }
              };
              check();
            })
            """
        )
    }
}
