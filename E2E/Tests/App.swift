import AppKit
import Foundation

/// Tests of the app as a whole: starting, loading a page, quitting. Fixtures in E2E/Fixtures/app/.
@MainActor
enum AppTests {
    static let all: [any E2ETest] = [AppLicensesTest(), AppQuitTest()]
}

/// Loads a fixture page in an off-screen window, checks that the page renders, and quits: every page closes within
/// 2 seconds, and Chromium's shutdown is done within 5 (spec/quit.md says why).
struct AppQuitTest: E2ETest {
    let name = "app.quit"
    let tags = ["smoke"]
    let quitsApp = true

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("app/index.html"))
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
        run.expectQuit(name, closingWithin: 2, stoppingWithin: 5)
    }
}

/// The built app carries CEF's license, Chromium's credits and Bow's license in its Resources, and the app menu
/// offers them through About Bow.
struct AppLicensesTest: E2ETest {
    let name = "app.licenses"

    func run(_ run: E2ERun) async throws {
        try await run.step("read license files", timeout: E2ETimeouts.step) {
            func has(_ file: String, _ text: String) -> Bool {
                guard let url = Bundle.main.url(forResource: file, withExtension: nil),
                    let data = try? Data(contentsOf: url)
                else { return false }
                return String(decoding: data, as: UTF8.self).contains(text)
            }
            let cef = has("CEF-LICENSE.txt", "Marshall A. Greenblatt")
            let chromium = has("Chromium-Credits.html", "<html")
            let bow = has("Bow-LICENSE.txt", "MIT License")
            let menu = await MainActor.run { NSApp.mainMenu?.items.first?.submenu?.items.first?.title == "About Bow" }
            func word(_ value: Bool) -> String { value ? "yes" : "no" }
            run.check(
                name, passed: cef && chromium && bow && menu,
                "cef=\(word(cef)) chromium=\(word(chromium)) bow=\(word(bow)) menu=\(word(menu))")
        }
    }
}
