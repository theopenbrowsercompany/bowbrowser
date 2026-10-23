import Foundation

/// Tests of the app as a whole: starting, loading a page, quitting. Fixtures in E2E/Fixtures/app/.
@MainActor
enum AppTests {
    static let all: [any E2ETest] = [AppQuitTest()]
}

/// Loads a fixture page in an off-screen window, checks that the page renders, and quits within 2 seconds.
struct AppQuitTest: E2ETest {
    let name = "app.quit"

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try run.app.openWindow(at: E2EFixture.url("app/index.html"))
        }
        try await run.step("load fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
            let heading = try await page.string("document.querySelector('h1')?.textContent ?? ''")
            guard heading == "Bow fixture" else { throw E2EError("the fixture heading is \"\(heading)\"") }
        }
        try await run.step("page renders", timeout: E2ETimeouts.step) {
            try await E2EWaits.untilRendering(page)
        }
        run.expectQuit(name, within: 2)
    }
}
