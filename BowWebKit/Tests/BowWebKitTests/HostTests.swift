import AppKit
import Testing
import WebKit

@testable import BowWebKit

/// The test process as a host for real web views, which every later BowWebKit test builds on: an off screen
/// window becomes key without activating the process, a web view loads a loopback page and a test world script
/// reads it, a synthetic click reaches the page as a trusted event, and an identified data store works and is
/// removed. Each test also checks no window of the process reached a screen.
@Suite(.serialized) @MainActor struct HostTests {
    init() {
        TestHost.start()
    }

    /// No window of the test process is on a screen, and the process never became active.
    private func expectIsolated() {
        IsolationMonitor.check()
        #expect(
            IsolationMonitor.violations.isEmpty, "isolation: windows seen on a screen \(IsolationMonitor.violations)")
        #expect(TestHost.refusedMoves.isEmpty, "something tried to move a test window onto a screen")
        #expect(!NSApp.isActive, "the test process became active")
        let ok = IsolationMonitor.violations.isEmpty && TestHost.refusedMoves.isEmpty && !NSApp.isActive
        print(
            "\(ok ? "PASS" : "FAIL") isolation: windows on a screen=\(IsolationMonitor.violations.count)"
                + " refused moves=\(TestHost.refusedMoves.count) active=\(NSApp.isActive)")
    }

    /// The page in an off screen window has focus (WebKit treats the window as key) while the process stays
    /// inactive, and showing a second window moves the focus to it.
    @Test func offScreenWindowIsKeyForThePageWithoutActivating() async throws {
        let server = try FixtureServer.started()
        defer { server.stop() }
        let (first, firstView) = try TestHost.webView()
        let (second, secondView) = try TestHost.webView()
        defer {
            _ = firstView.dispose()
            _ = secondView.dispose()
            TestHost.close(first)
            TestHost.close(second)
        }
        let one = PageDriver(firstView)
        let two = PageDriver(secondView)
        try await one.load(server.url("/host/index.html"))
        try await two.load(server.url("/host/index.html"))
        #expect(TestHost.holdsKey(second) && !TestHost.holdsKey(first))
        try await waitUntil("the second page has focus", timeout: 5) {
            try await two.bool("return document.hasFocus()")
        }
        #expect(!(try await one.bool("return document.hasFocus()")))
        TestHost.show(firstView, in: first)
        try await waitUntil("the first page has focus", timeout: 5) { try await one.bool("return document.hasFocus()") }
        try await waitUntil("the second page lost focus", timeout: 5) {
            !(try await two.bool("return document.hasFocus()"))
        }
        #expect(!TestHost.nearScreen(first.frame) && !TestHost.nearScreen(second.frame))
        expectIsolated()
    }

    @Test func webViewLoadsLoopbackPageAndScriptReadsIt() async throws {
        let server = try FixtureServer.started()
        defer { server.stop() }
        let (window, webView) = try TestHost.webView()
        defer {
            _ = webView.dispose()
            TestHost.close(window)
        }
        let driver = PageDriver(webView)
        try await driver.load(server.url("/host/index.html"))
        try await waitUntil("the title", timeout: 10) { webView.title == "Host" }
        #expect(webView.title == "Host")
        // Arguments are passed as values: the selector reaches the page as a string, never as source.
        let text = try await driver.string(
            "return document.querySelector(selector).textContent", ["selector": "#text"])
        #expect(text == "The test host page.")
        #expect(server.count(path: "/host/index.html") == 1)
        expectIsolated()
    }

    @Test func syntheticClickAndKeysReachPageAsTrustedEvents() async throws {
        let server = try FixtureServer.started()
        defer { server.stop() }
        let (window, webView) = try TestHost.webView()
        defer {
            _ = webView.dispose()
            TestHost.close(window)
        }
        let driver = PageDriver(webView)
        try await driver.load(server.url("/host/index.html"))
        try await waitUntil("the page has focus", timeout: 5) { try await driver.bool("return document.hasFocus()") }
        try await driver.click("#target")
        // The page's own script records the click in the DOM, which the test world reads (the two worlds share the
        // DOM, not their globals).
        let clicks = try await waitFor("the page saw the click", timeout: 5) { () -> [Bool]? in
            let text = try await driver.string("return document.getElementById('clicks').textContent")
            let list = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Bool]
            return list?.isEmpty == false ? list : nil
        }
        #expect(clicks == [true], "the page saw \(clicks); true is a trusted click")
        #expect(webView.mouseDowns == 1)
        // Keys reach the focused field as trusted events too.
        try await driver.click("#field")
        try driver.type("Ab")
        let value = try await waitFor("the field got the typed text", timeout: 5) { () -> String? in
            let text = try await driver.string("return document.getElementById('field').value")
            return text == "Ab" ? text : nil
        }
        #expect(value == "Ab")
        let keys = try await driver.string("return document.getElementById('keys').textContent")
        #expect(keys == "[true,true]", "the field saw keydowns \(keys); true is a trusted key")
        expectIsolated()
    }

    /// The fixture server: a registered route wins over files, a file outside the fixtures is refused, and byte
    /// ranges (start and end, open ended, suffix) are served.
    @Test func fixtureServerServesRoutesFilesAndRanges() async throws {
        let server = try FixtureServer.started()
        defer { server.stop() }
        server.route("/hop") { _ in .redirect(to: "/host/index.html") }
        func get(_ path: String, range: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: server.url(path))
            request.setValue(range, forHTTPHeaderField: "Range")
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let (status, page) = try await get("/host/index.html")
        #expect(status == 200)
        let (hopStatus, hopped) = try await get("/hop")
        #expect(hopStatus == 200 && hopped == page, "the redirect route did not lead to the page")
        #expect(try await get("/../Package.swift").0 == 404)
        #expect(try await get("/host/missing.html").0 == 404)
        let (r1, first) = try await get("/host/index.html", range: "bytes=0-14")
        #expect(r1 == 206 && first == page.prefix(15))
        let (r2, tail) = try await get("/host/index.html", range: "bytes=-10")
        #expect(r2 == 206 && tail == page.suffix(10))
        let (r3, rest) = try await get("/host/index.html", range: "bytes=10-")
        #expect(r3 == 206 && rest == page.dropFirst(10))
        #expect(server.count(path: "/hop") == 1)
    }

    @Test func identifiedDataStoreKeepsCookiesAndIsRemoved() async throws {
        let server = try FixtureServer.started()
        defer { server.stop() }
        server.route("/set") { _ in
            .html("<!doctype html><title>Set</title>", headers: ["Set-Cookie: host_check=1; Path=/; Max-Age=600"])
        }
        let stores = TestStores()
        let id = UUID()
        // The web view, its configuration and the store live only in this block, so they can be released; the
        // block's window is closed and its store removed even when the block throws, so no store outlives the test.
        var box: WeakBox?
        var failure: (any Error)?
        do {
            let store = stores.make(id: id)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            let (window, webView) = try TestHost.webView(configuration)
            defer {
                box = webView.dispose()
                TestHost.close(window)
            }
            let driver = PageDriver(webView)
            try await driver.load(server.url("/set"))
            #expect(store.isPersistent)
            #expect(store.identifier == id)
            let names = await store.httpCookieStore.allCookies().map(\.name)
            #expect(names.contains("host_check"))
            #expect(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id))
        } catch {
            failure = error
        }
        do {
            try await waitUntil("the web view is released", timeout: 5) { box?.object == nil }
        } catch {
            failure = failure ?? error
        }
        let left = await stores.removeAll()
        #expect(left.isEmpty, "stores still listed: \(left)")
        #expect(!(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id)))
        if let failure { throw failure }
        expectIsolated()
    }
}
