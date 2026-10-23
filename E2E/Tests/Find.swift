import Foundation

/// Tests of find in page. Fixtures in E2E/Fixtures/find/.
@MainActor
enum FindTests {
    static let all: [any E2ETest] = [FindBarTest()]
}

/// Opens the find bar with Edit > Find, types a word the fixture holds three times, steps with Enter and
/// Shift+Enter, and closes the bar with Escape, which leaves the active match selected in the page.
struct FindBarTest: E2ETest {
    let name = "find"

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("find/index.html"))
        }
        try await run.step("load fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }
        let bar = try await run.step("open find bar", timeout: E2ETimeouts.step) {
            let bar = try page.openFindBar()
            guard bar.hasKeyboard else { throw E2EError("the keyboard is not in the find bar's field") }
            return bar
        }
        let result = try await run.step("type", timeout: E2ETimeouts.step) {
            try bar.type("arrow")
            try await bar.waitForCount("1 of 3")
            return bar.lastResult
        }
        run.check(
            name, passed: result?.matches == 3 && result?.active == 1,
            "matches=\(result?.matches ?? -1) active=\(result?.active ?? -1)")

        // Enter steps forward and wraps from the last match to the first; Shift+Enter steps back and wraps too.
        var enter: [Int] = []
        for expected in [2, 3, 1] {
            try await run.step("press enter", timeout: E2ETimeouts.step) {
                try bar.press(.enter)
                try await bar.waitForCount("\(expected) of 3")
                enter.append(bar.lastResult?.active ?? 0)
            }
        }
        let shiftEnter = try await run.step("press shift enter", timeout: E2ETimeouts.step) {
            try bar.press(.shiftEnter)
            try await bar.waitForCount("3 of 3")
            return bar.lastResult?.active ?? 0
        }
        run.check(
            "find.step", passed: enter == [2, 3, 1] && shiftEnter == 3,
            "enter=\(enter.map(String.init).joined(separator: ",")) shift-enter=\(shiftEnter)")

        let selected = try await run.step("press escape", timeout: E2ETimeouts.step) {
            try bar.press(.escape)
            guard !bar.isShown else { throw E2EError("the find bar still shows") }
            guard bar.count.isEmpty else { throw E2EError("the find bar still counts \(bar.count)") }
            // Stopping keeps the active match as the page's selection: the third match after the steps above.
            return try await E2EWaits.until(page, "window.getSelection().anchorNode?.parentElement?.id") as? String
        }
        run.check("find.close", passed: selected == "m3", "hidden selection=\(selected ?? "none")")

        // Opening the bar again searches again for the text it kept; it stays open for final.png.
        let reopened = try await run.step("reopen find bar", timeout: E2ETimeouts.step) {
            let bar = try page.openFindBar()
            guard bar.hasKeyboard else { throw E2EError("the keyboard is not in the find bar's field") }
            try await bar.waitForCount("1 of 3")
            return bar
        }
        run.check(
            "find.reopen", passed: reopened.text == "arrow" && reopened.lastResult?.matches == 3,
            "text=\(reopened.text) count=\(reopened.count)")
    }
}
