import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// The status text follows the link under the pointer and changes once per link, through WebKit's hover callback
/// and through the script fallback.
@Suite(.serialized) @MainActor struct HoverStatusTests {
    init() {
        TestHost.start()
    }

    /// The copies of the hover script on `content` (other areas add scripts of their own).
    private func hoverScripts(_ content: WKUserContentController) -> Int {
        content.userScripts.filter { $0.source == WebKitTab.hoverScript }.count
    }

    private func statusTexts(_ delegate: RecordingTabDelegate) -> [String] {
        delegate.events.compactMap { if case .statusTextChanged(let text) = $0 { text } else { nil } }
    }

    /// A pointer move to `point` (page coordinates), delivered as AppKit delivers a real one: to the owners of the
    /// web view's mouse moved tracking areas (a synthetic event reaches no tracking area by itself, and the web view
    /// does not take a move as a responder). WebKit takes moves only in a key window, so the window reports key
    /// for every move: another suite's `TestHost.show` may have cleared it, and reporting key changes no other
    /// window's focus. Returns once WebKit has handled the move.
    private func move(_ webView: WKWebView, to point: CGPoint) async throws {
        guard let window = webView.window as? TestWindow else { throw TestError("the web view is in no test window") }
        window.reportsKey = true
        let at = PageDriver(webView).windowPoint(point)
        guard
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { throw TestError("could not make a mouse move") }
        // The owner need not be a responder: AppKit sends it `mouseMoved:` all the same.
        let owners = webView.trackingAreas.filter { $0.options.contains(.mouseMoved) }.compactMap(\.owner)
        guard !owners.isEmpty else { throw TestError("the web view has no mouse moved tracking area") }
        for owner in owners {
            guard owner.responds(to: #selector(NSResponder.mouseMoved(with:))) else {
                throw TestError("a tracking area owner takes no mouse moves")
            }
            _ = owner.perform(#selector(NSResponder.mouseMoved(with:)), with: event)
        }
        #expect(await WebKitSPI.afterPendingMouseEvents(webView), "WebKit did not finish the pointer move")
    }

    /// The rectangle of `selector` in page coordinates.
    private func rect(_ driver: PageDriver, _ selector: String) async throws -> CGRect {
        let value = try await driver.eval(
            "const r = document.querySelector(selector).getBoundingClientRect(); return [r.left, r.top, r.width, r.height];",
            ["selector": selector])
        guard let n = value as? [NSNumber], n.count == 4 else { throw TestError("no element \(selector)") }
        return CGRect(x: n[0].doubleValue, y: n[1].doubleValue, width: n[2].doubleValue, height: n[3].doubleValue)
    }

    /// From the gap onto link one, along it, straight onto link two (its label, a child of the link) and off again:
    /// link one, link two, then "", each once.
    private func walk(source: HoverStatus.Source) async throws {
        let rig = try TabRig()
        let key = ObjectIdentifier(rig.profile)
        if source == .script { WebKitTab.hoverScriptProfiles.insert(key) }
        defer { WebKitTab.hoverScriptProfiles.remove(key) }
        let tab = rig.tab("/hover/index.html")
        #expect(tab.hover.source == source)
        do {
            try await InputLock.run { try await walk(tab, rig, source) }
            if source == .script { reinstallOnSharedController(tab, rig) }
        } catch {
            try? await rig.finish()
            throw error
        }
        try await rig.finish()
    }

    /// The copies of the hover script on `content` (other areas add scripts of their own).
    private func hoverScripts(_ content: WKUserContentController) -> Int {
        content.userScripts.filter { $0.source == WebKitTab.hoverScript }.count
    }

    /// A web view on a content controller that already has the script (WebKit shares one with a popup) installs
    /// without raising for the handler name and without a second copy of the script.
    private func reinstallOnSharedController(_ tab: WebKitTab, _ rig: TabRig) {
        guard let content = tab.webView?.configuration.userContentController else { return }
        let shared = WKWebViewConfiguration()
        shared.websiteDataStore = rig.profile.store
        shared.userContentController = content
        tab.releaseWebView()
        tab.install(WebKitWebView(frame: .zero, configuration: shared))
        #expect(tab.webView?.configuration.userContentController === content)
        #expect(hoverScripts(content) == 1, "hover scripts on the shared controller: \(hoverScripts(content))")
    }

    /// The walk itself, holding the web view only while it runs, so `finish()` can check it is released.
    private func walk(_ tab: WebKitTab, _ rig: TabRig, _ source: HoverStatus.Source) async throws {
        let page = rig.url("/hover/index.html")
        try await rig.waitFor("finish \(page)")
        let webView = try #require(tab.webView)
        let driver = PageDriver(webView)
        // The rectangles are read from the laid out document, so wait for it, not only the navigation's finish.
        try await driver.waitForLoad(of: page)
        let one = try await rect(driver, "#one")
        let two = try await rect(driver, "#two-label")
        let gap = try await rect(driver, "#gap")
        let off = CGPoint(x: gap.maxX - 20, y: gap.midY)

        try await move(webView, to: off)
        for x in stride(from: one.minX + 10, through: one.maxX - 10, by: 20) {
            try await move(webView, to: CGPoint(x: x, y: one.midY))
        }
        try await move(webView, to: CGPoint(x: two.midX, y: two.midY))
        try await move(webView, to: CGPoint(x: two.midX + 2, y: two.midY + 2))
        try await move(webView, to: off)
        try await move(webView, to: CGPoint(x: off.x - 5, y: off.y))

        let expected = [rig.url("/hover/one.html").absoluteString, rig.url("/hover/two.html").absoluteString, ""]
        // A timeout is reported by the comparison below, with the texts seen.
        try? await waitUntil("the status texts \(expected)", timeout: 5) {
            statusTexts(rig.delegate).count >= expected.count && tab.hover.text == ""
        }
        // One more round trip through the page, so a late repeat would have arrived.
        _ = await WebKitSPI.afterPendingMouseEvents(webView)
        _ = try await driver.string("return document.title")
        let seen = statusTexts(rig.delegate)
        #expect(seen == expected)
        switch source {
        case .callback:
            // WebKit really calls the private callback (moves it coalesces under load share one call), and the tab
            // added no script.
            #expect(tab.hover.callbackCount >= expected.count, "hover callbacks: \(tab.hover.callbackCount)")
            #expect(hoverScripts(webView.configuration.userContentController) == 0)
        case .script:
            #expect(tab.hover.callbackCount == 0)
            #expect(hoverScripts(webView.configuration.userContentController) == 1)
            // Neither the page nor another world sees the script's message handler.
            let pageSees = try await webView.evaluateJavaScript(
                "typeof window.webkit?.messageHandlers?.bowHoverStatus")
            #expect(pageSees as? String == "undefined")
            #expect(
                try await driver.string("return typeof window.webkit?.messageHandlers?.bowHoverStatus") == "undefined")
        }
        let ok = seen == expected
        print(
            "\(ok ? "PASS" : "FAIL") hover.\(source): status texts \(seen.map { $0.isEmpty ? "\"\"" : $0 })"
                + " callbacks=\(tab.hover.callbackCount)")
    }

    @Test func hoverCallbackChangesTheStatusOncePerLink() async throws {
        #expect(
            WebKitSPI.isPresent(WebKitSPI.Callback.mouseDidMoveOverElement.entry),
            "WebKit does not declare the hover callback; tabs use the script")
        try await walk(source: .callback)
    }

    @Test func hoverScriptChangesTheStatusOncePerLink() async throws {
        try await walk(source: .script)
    }
}
