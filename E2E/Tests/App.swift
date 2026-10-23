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

/// The built app carries CEF's license, Chromium's credits and Bow's license in its Resources, and Bow > About Bow,
/// chosen through the app menu, opens the About panel with a link to each that points at a file in the built app.
struct AppLicensesTest: E2ETest {
    let name = "app.licenses"
    let checks = ["app.licenses", "app.licenses.menu", "app.licenses.about", "app.licenses.links"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2ELicensesApp else { throw E2EError("the app has no About Bow check") }
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            try await run.app.openWindow(at: E2EFixture.url("app/index.html"))
        }
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
            func word(_ value: Bool) -> String { value ? "yes" : "no" }
            run.check(
                name, passed: cef && chromium && bow, "cef=\(word(cef)) chromium=\(word(chromium)) bow=\(word(bow))")
        }
        try await run.step("About Bow item", timeout: E2ETimeouts.step) {
            let item = NSApp.mainMenu?.items.first?.submenu?.items.first
            item?.menu?.update()
            let wired =
                item?.title == "About Bow" && item?.action == #selector(Licenses.showAbout(_:))
                && item?.target === Licenses.self && item?.isEnabled == true
            run.check(
                "app.licenses.menu", passed: wired,
                "title=\(item?.title ?? "none") action=\(item?.action.map { "\($0)" } ?? "none") enabled=\(item?.isEnabled == true)"
            )
        }
        try await run.step("choose About Bow", timeout: E2ETimeouts.step) {
            let options = try app.chooseAbout(in: page)
            let credits = options?[.credits] as? NSAttributedString
            run.check(
                "app.licenses.about", passed: credits != nil,
                credits == nil ? "choosing About Bow did not ask for the About panel" : "the About panel was asked for")
            guard let credits else {
                run.check("app.licenses.links", passed: false, "no credits to read")
                return
            }
            var links: [String: URL] = [:]
            credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, range, _ in
                if let url = value as? URL { links[credits.attributedSubstring(from: range).string] = url }
            }
            let resources = Bundle.main.resourceURL?.standardizedFileURL.path ?? ""
            var problems: [String] = []
            for file in Licenses.files {
                guard let url = links[file.label] else {
                    problems.append("\(file.label): no link")
                    continue
                }
                let size = (try? Data(contentsOf: url).count) ?? 0
                if !url.isFileURL || url.lastPathComponent != file.name
                    || !url.standardizedFileURL.path.hasPrefix(resources) || size == 0
                {
                    problems.append("\(file.label): \(url.path) is not a file of the app")
                }
            }
            run.check(
                "app.licenses.links", passed: problems.isEmpty,
                problems.isEmpty ? "3 links read from the app's Resources" : problems.joined(separator: "; "))
        }
    }
}
