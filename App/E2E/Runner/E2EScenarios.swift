import Foundation

/// One e2e scenario: steps that drive the app through E2EApp and E2EPage, and the checks they record.
@MainActor
protocol E2EScenario {
    /// The name `--e2e=<name>` selects, also used for its check lines.
    var name: String { get }
    func run(_ run: E2ERun) async throws
}

@MainActor
enum E2EScenarios {
    /// Every scenario, in the order `--e2e=all` runs them.
    static let all: [any E2EScenario] = [AppQuitScenario()]

    /// The first load waits for Chromium's helpers to start, which parallel builds can slow down a lot.
    static let firstLoadTimeout: TimeInterval = 15
    static let stepTimeout: TimeInterval = 5
}

/// Fixture page URLs, served from App/E2E/Fixtures.
enum Fixture {
    static func url(_ path: String) -> URL {
        URL(string: "https://bow.test/\(path)")!
    }
}

/// Loads a fixture page in an off-screen window, checks that the page renders, and quits within 2 seconds.
struct AppQuitScenario: E2EScenario {
    let name = "app.quit"

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2EScenarios.stepTimeout) {
            try run.app.openWindow(at: Fixture.url("index.html"))
        }
        try await run.step("load fixture", timeout: E2EScenarios.firstLoadTimeout) {
            let status = try await page.waitForLoad()
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
            let heading = try await page.string("document.querySelector('h1')?.textContent ?? ''")
            guard heading == "Bow fixture" else { throw E2EError("the fixture heading is \"\(heading)\"") }
        }
        try await run.step("page renders", timeout: E2EScenarios.stepTimeout) {
            try await E2EChecks.expectRendering(page)
        }
        run.expectQuit(name, within: 2)
    }
}

/// Assertions shared by scenarios.
@MainActor
enum E2EChecks {
    /// Throws unless the page counts as visible and is painting frames, which an off-screen window must still do.
    static func expectRendering(_ page: any E2EPage) async throws {
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
}
