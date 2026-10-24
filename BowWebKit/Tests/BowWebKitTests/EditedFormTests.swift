import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// The edited form signal: typing into a field turns `hasEditedForm` on, a page script changing a field does not, a
/// new document clears it, and the page cannot see the script that reports it.
@Suite(.serialized) @MainActor struct EditedFormTests {
    init() {
        TestHost.start()
    }

    private func editedStates(_ delegate: RecordingTabDelegate) -> [Bool] {
        delegate.events.compactMap { if case .stateChanged(let s) = $0 { s.hasEditedForm } else { nil } }
    }

    /// The page's own global names, read in the page's world.
    private func pageGlobals(_ webView: WKWebView) async throws -> [String] {
        let value = try await webView.evaluateJavaScript("JSON.stringify(Object.getOwnPropertyNames(window).sort())")
        let text = try #require(value as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String])
    }

    /// Types `text` into the field `selector` with real key events. The window reports key and the web view is its
    /// first responder, so WebKit gives the page focus for the keys. Another suite's `TestHost.show` can take key
    /// from the window between two steps, so each try asserts key again, and a try whose keys did not all reach the
    /// field empties it by script (which fires no event) and types again.
    private func type(_ text: String, into selector: String, _ driver: PageDriver, _ window: TestWindow) async throws {
        _ = try await waitFor("\(text) typed into \(selector)", timeout: 30) { () -> Bool? in
            window.reportsKey = true
            window.makeFirstResponder(driver.webView)
            guard try await driver.bool("return document.hasFocus()") else { return nil }
            _ = try await driver.eval("document.querySelector(selector).value = ''", ["selector": selector])
            try await driver.click(selector)
            try driver.type(text)
            return try? await waitFor("the field got \(text)", timeout: 5) {
                try await driver.string("return document.querySelector(selector).value", ["selector": selector])
                    == text ? true : nil
            }
        }
    }

    @Test func typingMarksTheFormEditedAndANewDocumentClearsIt() async throws {
        let rig = try TabRig()
        do {
            try await run(rig)
        } catch {
            try? await rig.finish()
            throw error
        }
        try await rig.finish()
    }

    private func run(_ rig: TabRig) async throws {
        let page = rig.url("/forms/index.html")
        let tab = rig.tab("/forms/index.html")
        try await rig.waitFor("finish \(page)")
        let webView = try #require(tab.webView)
        let driver = PageDriver(webView)
        try await driver.waitForLoad(of: page)

        // A page script setting a field's value, and dispatching input and change events of its own, is no edit.
        _ = try await webView.evaluateJavaScript(
            """
            const field = document.getElementById('scripted');
            field.value = 'set by script';
            field.dispatchEvent(new Event('input', { bubbles: true }));
            field.dispatchEvent(new Event('change', { bubbles: true }));
            true
            """)
        // Any message the script posted for those events arrives before the reply to a later page read.
        #expect(try await driver.string("return document.getElementById('scripted').value") == "set by script")
        let scripted = !tab.state.hasEditedForm && !editedStates(rig.delegate).contains(true)
        #expect(scripted, "a page script marked the form edited")
        print("\(scripted ? "PASS" : "FAIL") pageSignals.editedForm.scripted: hasEditedForm=\(tab.state.hasEditedForm)")

        // Typing into a field is an edit.
        try await type("Ab", into: "#name", driver, rig.window)
        rig.window.reportsKey = false
        // Waits on the value checked next.
        try? await waitUntil("hasEditedForm true", timeout: 10) { tab.state.hasEditedForm }
        let typed = tab.state.hasEditedForm && editedStates(rig.delegate).last == true
        #expect(typed, "typing did not mark the form edited; states \(editedStates(rig.delegate))")
        print("\(typed ? "PASS" : "FAIL") pageSignals.editedForm.typed: hasEditedForm=\(tab.state.hasEditedForm)")

        // The page sees no trace of the script: its globals are those of a web view without Bow's scripts, and the
        // message handler is neither in the page's world nor in another one.
        let pageSeesHandler = try await webView.evaluateJavaScript(
            "typeof window.webkit?.messageHandlers?.bowPageSignals")
        let testWorldSeesHandler = try await driver.string(
            "return typeof window.webkit?.messageHandlers?.bowPageSignals")
        let globals = try await pageGlobals(webView)
        // In a window of its own that is not made key (`TestHost.webView` would take key from other suites).
        let window = try TestHost.window()
        let bare = TestWebView(frame: window.contentView?.bounds ?? .zero, configuration: TestHost.configuration())
        WebKitSPI.setWindowOcclusionDetectionEnabled(bare, false)
        window.contentView?.addSubview(bare)
        defer {
            _ = bare.dispose()
            TestHost.close(window)
        }
        try await PageDriver(bare).load(page)
        let bareGlobals = try await pageGlobals(bare)
        let invisible =
            pageSeesHandler as? String == "undefined" && testWorldSeesHandler == "undefined" && globals == bareGlobals
        #expect(pageSeesHandler as? String == "undefined")
        #expect(testWorldSeesHandler == "undefined")
        #expect(globals == bareGlobals, "page globals differ: \(Set(globals).symmetricDifference(bareGlobals))")
        print(
            "\(invisible ? "PASS" : "FAIL") pageSignals.editedForm.invisible: handler in page=\(pageSeesHandler ?? "nil")"
                + " in another world=\(testWorldSeesHandler) globals equal=\(globals == bareGlobals)")

        // A new main frame document clears it.
        let next = rig.url("/forms/next.html")
        tab.load(next)
        try await rig.waitFor("commit \(next)")
        // Waits on the value checked next.
        try? await waitUntil("hasEditedForm false", timeout: 5) { !tab.state.hasEditedForm }
        let cleared = !tab.state.hasEditedForm && editedStates(rig.delegate).last == false
        #expect(cleared, "the new document kept the edited signal")
        print("\(cleared ? "PASS" : "FAIL") pageSignals.editedForm.cleared: hasEditedForm=\(tab.state.hasEditedForm)")

        // Back to the form: restored from the back and forward cache it still holds the typed text and is edited
        // again; loaded afresh it is empty and not edited.
        try await rig.waitFor("finish \(next)")
        rig.delegate.reset()
        tab.goBack()
        try await rig.waitFor("finish \(page)")
        let restoredText = try await driver.string("return document.getElementById('name').value")
        let fromCache = restoredText == "Ab"
        try? await waitUntil("hasEditedForm \(fromCache)", timeout: 10) { tab.state.hasEditedForm == fromCache }
        let back = tab.state.hasEditedForm == fromCache
        #expect(back, "back to the form (from the cache: \(fromCache)): hasEditedForm=\(tab.state.hasEditedForm)")
        print(
            "\(back ? "PASS" : "FAIL") pageSignals.editedForm.back: from the cache=\(fromCache)"
                + " hasEditedForm=\(tab.state.hasEditedForm)")
    }

    /// A web view on a content controller that already has the scripts (WebKit shares one with a popup) installs
    /// without raising for the handler name and without second copies of the scripts.
    @Test func aSharedContentControllerGetsTheScriptsOnce() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/forms/index.html")
        let content = try #require(tab.webView?.configuration.userContentController)
        let shared = WKWebViewConfiguration()
        shared.websiteDataStore = rig.profile.store
        shared.userContentController = content
        tab.releaseWebView()
        tab.install(WebKitWebView(frame: .zero, configuration: shared))
        #expect(tab.webView?.configuration.userContentController === content)
        let sources = [WebKitTab.editedFormScript, WebKitTab.faviconScript]
        #expect(content.userScripts.filter { sources.contains($0.source) }.count == 2)
        try await rig.finish()
    }
}
