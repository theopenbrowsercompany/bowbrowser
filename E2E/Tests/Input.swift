import Foundation

/// Tests of input inside web pages: clicking, typing and keys. Fixtures in E2E/Fixtures/input/.
@MainActor
enum InputTests {
    static let all: [any E2ETest] = [InputTypeTest()]
}

/// Clicks into a form field, types into it, corrects it with Backspace and clicks the form's button,
/// then checks the value the page's click handler saw.
struct InputTypeTest: E2ETest {
    let name = "input.type"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("input/index.html"))
        }
        try await run.step("load fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }
        try await run.step("focus field", timeout: E2ETimeouts.step) {
            try await page.click("#name")
            try await E2EWaits.until(page, "document.activeElement?.id === 'name'")
            // The window is never key; focus emulation is what lets the page count as focused.
            let focused = try await page.evaluate("document.hasFocus()")
            guard focused as? Bool == true else { throw E2EError("document.hasFocus() is false") }
            // A real click grants user activation, which pages need for prompts such as beforeunload.
            let active = try await page.evaluate("navigator.userActivation.hasBeenActive")
            guard active as? Bool == true else { throw E2EError("the click gave the page no user activation") }
        }
        try await run.step("type", timeout: E2ETimeouts.step) {
            try await page.type("hellox")
            try await E2EWaits.until(page, "document.getElementById('name').value === 'hellox'")
            try await page.press(.backspace)
            try await E2EWaits.until(page, "document.getElementById('name').value === 'hello'")
        }
        let value = try await run.step("click button", timeout: E2ETimeouts.step) {
            try await page.click("#submit")
            try await E2EWaits.until(page, "window.submitted !== null")
            return try await page.string("window.submitted")
        }
        run.check(name, passed: value == "hello", "value=\(value)")
    }
}
