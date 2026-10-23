import Foundation

/// Tests of the page signals that keep a tab loaded: sound a page plays through an audio element or Web Audio, and
/// form input that reaches the page with no key event (Edit > Paste, an input method's text as dictation inserts
/// it). Each signal comes from the page itself, through the render process, not from a test seam.
@MainActor
enum UnloadSignalTests {
    static let all: [any E2ETest] = [UnloadAudiblePageTest(), UnloadFormPasteTest(), UnloadFormDictationTest()]

    /// Waits until the unloader's view of tab `item` satisfies `done` and returns it.
    static func tabState(
        _ app: any E2EUnloadApp, _ item: String, besides page: any E2EPage,
        until done: (E2EUnloadTabState) -> Bool
    ) async throws -> E2EUnloadTabState {
        try await E2EWaits.value({ try app.unloadTabState(item, besides: page) }, until: done)
    }

    /// Opens the form fixture in a window, focuses its field, enters `text` with `enter` (which must send no key
    /// event), then shows another tab and runs a pass after a day idle. Checks that the form's tab stayed loaded with
    /// the text and that no key reached the page.
    static func formKept(
        _ run: E2ERun, check name: String, text: String,
        enter: @escaping @MainActor (_ app: any E2EUnloadApp, _ form: any E2EPage) async throws -> Void
    ) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let form = try await run.step("open the form", timeout: E2ETimeouts.firstLoad) {
            let form = try await run.app.openWindow(at: E2EFixture.url("unload/form.html"))
            _ = try await form.waitForLoad(after: 0)
            return form
        }
        let item = try app.unloadItem(of: form)
        let (entered, edited) = try await run.step("enter text without a key", timeout: E2ETimeouts.step) {
            try await form.click("#field")
            try await enter(app, form)
            try await E2EWaits.until(form, "document.getElementById('field').value === \(jsLiteral(text))")
            let state = try await tabState(app, item, besides: form) { $0.hasEditedForm }
            return (try await form.string("document.getElementById('field').value"), state.hasEditedForm)
        }
        let keys = try await form.evaluate("window.keys") as? Int ?? -1
        let page = try await run.step("switch to another tab", timeout: E2ETimeouts.firstLoad) {
            let page = try run.app.openTab(at: UnloadTests.url("home"), besides: form, select: true)
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let (unloaded, state, kept) = try await run.step("pass after a day idle", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let unloaded = try await app.runUnloadPass()
            let state = try app.unloadTabState(item, besides: page)
            let kept = state.isLoaded ? try await form.string("document.getElementById('field').value") : ""
            return (unloaded, state, kept)
        }
        run.check(
            name, passed: edited && keys == 0 && unloaded == 0 && state.isLoaded && kept == entered,
            "unloaded=\(unloaded) tab=\(UnloadTests.describe(state)) edited=\(edited) keys=\(keys) text=\"\(kept)\"")
    }

    /// `value` as a JavaScript string literal.
    static func jsLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

/// A background tab playing a quiet tone stays loaded past the idle limit: first through an audio element, then
/// through Web Audio. Once its sound stopped, it stays loaded 20 seconds on the unloader's clock and unloads 31
/// seconds on.
struct UnloadAudiblePageTest: E2ETest {
    let name = "unload.audible_page"

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let sound = try await run.step("open the sound page", timeout: E2ETimeouts.firstLoad) {
            let sound = try await run.app.openWindow(at: E2EFixture.url("unload/audible.html"))
            _ = try await sound.waitForLoad(after: 0)
            // The click is the user activation that lets the page start sound.
            try await sound.click("#activate")
            try await E2EWaits.until(sound, "window.activated === true")
            return sound
        }
        let item = try app.unloadItem(of: sound)
        let home = try await run.step("play through the element in a background tab", timeout: E2ETimeouts.firstLoad) {
            let started = try await sound.string("startElement()")
            guard started == "playing" else { throw E2EError("the element did not play: \(started)") }
            let home = try run.app.openTab(at: UnloadTests.url("home"), besides: sound, select: true)
            _ = try await home.waitForLoad(after: 0)
            return home
        }
        func pass() async throws -> E2EUnloadTabState {
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            _ = try await app.runUnloadPass()
            return try app.unloadTabState(item, besides: home)
        }
        let element = try await run.step("pass after a day idle while the element plays", timeout: E2ETimeouts.step) {
            let playing = try await UnloadSignalTests.tabState(app, item, besides: home) { $0.isAudible }
            guard playing.isAudible else { throw E2EError("the tab never reported the element's sound") }
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            return try await pass()
        }
        let webAudio = try await run.step("pass after a day idle while Web Audio plays", timeout: E2ETimeouts.step) {
            _ = try await sound.evaluate("stopElement()")
            let quiet = try await UnloadSignalTests.tabState(app, item, besides: home) { !$0.isAudible }
            guard !quiet.isAudible else { throw E2EError("the tab never reported the element stopped") }
            let state = try await sound.string("startWebAudio()")
            guard state == "running" else { throw E2EError("Web Audio did not start: \(state)") }
            let playing = try await UnloadSignalTests.tabState(app, item, besides: home) { $0.isAudible }
            guard playing.isAudible else { throw E2EError("the tab never reported Web Audio's sound") }
            return try await pass()
        }
        let (within, after) = try await run.step("stop, then pass 20 and 31 seconds on", timeout: E2ETimeouts.step) {
            _ = try await sound.evaluate("stopWebAudio()")
            let quiet = try await UnloadSignalTests.tabState(app, item, besides: home) { !$0.isAudible }
            guard !quiet.isAudible else { throw E2EError("the tab never reported Web Audio stopped") }
            try app.advanceUnloadClock(by: 20)
            _ = try await app.runUnloadPass()
            let within = try app.unloadTabState(item, besides: home)
            try app.advanceUnloadClock(by: 11)
            _ = try await app.runUnloadPass()
            return (within, try app.unloadTabState(item, besides: home))
        }
        run.check(
            name,
            passed: element.isLoaded && webAudio.isLoaded && within.isLoaded && !after.isLoaded && after.isListed,
            "element=\(UnloadTests.describe(element)) webaudio=\(UnloadTests.describe(webAudio))"
                + " within=\(UnloadTests.describe(within)) after=\(UnloadTests.describe(after))")
    }
}

/// Text pasted into a field through Edit > Paste, with no key event, keeps its tab loaded past the idle limit.
struct UnloadFormPasteTest: E2ETest {
    let name = "unload.form_paste"

    func run(_ run: E2ERun) async throws {
        let text = "pasted reply"
        try await UnloadSignalTests.formKept(run, check: name, text: text) { app, form in
            let pasted = try await app.pasteThroughEditMenu(text, in: form) {
                try await E2EWaits.until(form, "document.getElementById('field').value.length > 0")
                return true
            }
            guard pasted else { throw E2EError("the field never got the pasted text") }
        }
    }
}

/// Text an input method commits into a field, as dictation does, with no key event, keeps its tab loaded past the
/// idle limit.
struct UnloadFormDictationTest: E2ETest {
    let name = "unload.form_dictation"

    func run(_ run: E2ERun) async throws {
        try await UnloadSignalTests.formKept(run, check: name, text: "dictated reply") { _, form in
            try await form.type("dictated reply")
        }
    }
}
