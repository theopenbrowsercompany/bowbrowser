import BowCore
import Foundation
import Testing
import WebKit

@testable import BowWebKit

/// Find in page through WebKit's private find gives the engine's own counts (frozen in `Fixtures/find/expected.json`
/// by the W1 spike) on pages with frames and hidden text, with the active match BowCore's tracker keeps; the public
/// fallback says only found or not.
@Suite(.serialized) @MainActor struct FindTests {
    struct Expected: Decodable {
        var query: String
        var counts: [String: Int]
    }

    static let fixtures = ["plain.html", "iframe-same.html", "iframe-cross.html", "hidden.html"]

    init() {
        TestHost.start()
    }

    private func expected() throws -> Expected {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/find/expected.json")
        return try JSONDecoder().decode(Expected.self, from: Data(contentsOf: url))
    }

    private func results(_ delegate: RecordingTabDelegate) -> [FindResult] {
        delegate.events.compactMap { if case .findResult(let r) = $0 { r } else { nil } }
    }

    /// Hears every frame's document end, from the test world, so a test waits for a frame by its address: the main
    /// frame's finish can come before a cross origin frame's document is in.
    final class FrameWatcher: NSObject, WKScriptMessageHandler {
        static let name = "bowFindFrameLoaded"
        var urls: [String] = []

        nonisolated func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated {
                if let url = message.body as? String { urls.append(url) }
            }
        }

        /// Starts hearing `tab`'s frames, from its next load on.
        static func watching(_ tab: WebKitTab) throws -> FrameWatcher {
            let watcher = FrameWatcher()
            let controller = try #require(tab.webView).configuration.userContentController
            controller.addUserScript(
                WKUserScript(
                    source: "window.webkit.messageHandlers.\(name).postMessage(location.href);",
                    injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: PageDriver.world))
            controller.add(watcher, contentWorld: PageDriver.world, name: name)
            return watcher
        }
    }

    /// The frame each fixture holds, on the server's main origin or its other one.
    private func frameURL(of name: String, _ rig: TabRig) -> String? {
        switch name {
        case "iframe-same.html": rig.server.base + "/find/frame.html"
        case "iframe-cross.html": rig.server.otherBase + "/find/frame.html"
        default: nil
        }
    }

    /// Loads `path` in `tab` and waits until its main frame finished and the document of its frame (if any) is in.
    private func load(_ path: String, in tab: WebKitTab, _ rig: TabRig, _ watcher: FrameWatcher) async throws {
        let url = rig.url(path)
        rig.delegate.reset()
        watcher.urls = []
        tab.load(url)
        try await rig.waitFor("finish \(url)")
        let name = String(path.split(separator: "/").last ?? "")
        let frame = frameURL(of: name, rig)
        try await waitUntil("the documents of \(path); saw \(watcher.urls)", timeout: 10) {
            watcher.urls.contains(url.absoluteString) && (frame.map(watcher.urls.contains) ?? true)
        }
    }

    /// Waits for the first find result after `index` results and returns it.
    private func nextResult(after index: Int, _ rig: TabRig, _ what: String) async throws -> FindResult {
        try await waitFor("\(what); saw \(results(rig.delegate))", timeout: 5) {
            let all = results(rig.delegate)
            return all.count > index ? all[index] : nil
        }
    }

    @Test func countsAndActiveMatchEqualTheEnginesExpectedCounts() async throws {
        let expected = try expected()
        let rig = try TabRig()
        let tab = rig.tab("/navigation/start.html")
        try await rig.waitFor("finish \(rig.url("/navigation/start.html"))")
        let watcher = try FrameWatcher.watching(tab)
        for name in Self.fixtures {
            let want = try #require(expected.counts[name])
            try await load("/find/\(name)", in: tab, rig, watcher)
            tab.find(expected.query, forward: true, matchCase: false)
            let first = try await nextResult(after: 0, rig, "\(name) count")
            #expect(first == FindResult(matchCount: want, activeMatch: 1, isFinal: true), "\(name)")

            // Forward through every match and one more: the active match wraps from the count to 1.
            var actives: [Int] = []
            for _ in 0..<want {
                tab.find(expected.query, forward: true, matchCase: false)
                actives.append(results(rig.delegate).last?.activeMatch ?? -1)
            }
            #expect(actives == Array(2...want) + [1], "\(name) forward")
            // Back from 1 wraps to the count.
            tab.find(expected.query, forward: false, matchCase: false)
            #expect(results(rig.delegate).last == FindResult(matchCount: want, activeMatch: want, isFinal: true))
            #expect(results(rig.delegate).allSatisfy { $0.matchCount == want }, "\(name)")

            if name == "plain.html" {
                // The private find moved the page's selection onto a match.
                let page = PageDriver(tab.webView!)
                try await waitUntil("the selection on a match", timeout: 5) {
                    try await page.string("return String(getSelection())").lowercased() == expected.query
                }
            }
            tab.stopFind()
        }
        try await rig.finish()
    }

    @Test func matchCaseNoMatchAndStop() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/find/plain.html")
        try await rig.waitFor("finish \(rig.url("/find/plain.html"))")

        tab.find("quokka", forward: true, matchCase: true)
        #expect(
            try await nextResult(after: 0, rig, "match case")
                == FindResult(matchCount: 2, activeMatch: 1, isFinal: true))

        tab.find("wombat", forward: true, matchCase: false)
        #expect(
            try await nextResult(after: 1, rig, "no match") == FindResult(matchCount: 0, activeMatch: 0, isFinal: true))
        tab.find("wombat", forward: true, matchCase: false)
        #expect(results(rig.delegate).last == FindResult(matchCount: 0, activeMatch: 0, isFinal: true))

        // Stopping clears the search: the same text again starts at 1 and counts again.
        rig.delegate.reset()
        tab.find("quokka", forward: true, matchCase: false)
        _ = try await nextResult(after: 0, rig, "before stop")
        tab.find("quokka", forward: true, matchCase: false)
        tab.find("quokka", forward: true, matchCase: false)
        #expect(results(rig.delegate).last?.activeMatch == 3)
        tab.stopFind()
        tab.find("quokka", forward: true, matchCase: false)
        #expect(
            try await nextResult(after: 3, rig, "after stop")
                == FindResult(matchCount: 4, activeMatch: 1, isFinal: true))

        // The count of a search stopped before it arrived is dropped: WebKit answers in order, so the next
        // search's count comes after it.
        rig.delegate.reset()
        tab.stopFind()
        tab.find("quokka", forward: true, matchCase: false)
        tab.stopFind()
        tab.find("path", forward: true, matchCase: false)
        _ = try await nextResult(after: 0, rig, "path")
        #expect(results(rig.delegate) == [FindResult(matchCount: 1, activeMatch: 1, isFinal: true)])
        try await rig.finish()
    }

    @Test func aNewPageStartsANewSearch() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/find/plain.html")
        try await rig.waitFor("finish \(rig.url("/find/plain.html"))")
        tab.find("quokka", forward: true, matchCase: false)
        _ = try await nextResult(after: 0, rig, "plain")
        tab.find("quokka", forward: true, matchCase: false)
        #expect(results(rig.delegate).last?.activeMatch == 2)

        try await load("/find/iframe-same.html", in: tab, rig, try FrameWatcher.watching(tab))
        tab.find("quokka", forward: true, matchCase: false)
        #expect(
            try await nextResult(after: 0, rig, "iframe-same")
                == FindResult(matchCount: 5, activeMatch: 1, isFinal: true))
        try await rig.finish()
    }

    @Test func thePublicFallbackSaysOnlyFoundOrNot() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/find/iframe-same.html")
        try await rig.waitFor("finish \(rig.url("/find/iframe-same.html"))")
        tab.finder.forcesPublicFind = true
        tab.find("quokka", forward: true, matchCase: false)
        #expect(try await nextResult(after: 0, rig, "found") == TabFinder.approximate(found: true))
        tab.find("wombat", forward: true, matchCase: false)
        #expect(try await nextResult(after: 1, rig, "not found") == TabFinder.approximate(found: false))
        #expect(TabFinder.approximate(found: true) == FindResult(matchCount: 1, activeMatch: 1, isFinal: false))
        #expect(TabFinder.approximate(found: false) == FindResult(matchCount: 0, activeMatch: 0, isFinal: true))
        try await rig.finish()
    }

    /// A page with more matches than WebKit counts shows the cap, and stepping back from 1 wraps to it.
    @Test func moreMatchesThanTheCapShowTheCap() async throws {
        let rig = try TabRig()
        let words = Array(repeating: "quokka", count: Int(TabFinder.maxCount) + 200).joined(separator: " ")
        rig.server.route("/many") { _ in .html("<!doctype html><title>Many</title><p>\(words)</p>") }
        let tab = rig.tab("/many")
        try await rig.waitFor("finish \(rig.url("/many"))")
        let delegate = SPIFindDelegate()
        var raw: [UInt] = []
        delegate.onCount = { count, _ in raw.append(count) }
        tab.find("quokka", forward: true, matchCase: false)
        let cap = Int(TabFinder.maxCount)
        #expect(
            try await nextResult(after: 0, rig, "many") == FindResult(matchCount: cap, activeMatch: 1, isFinal: true))
        tab.find("quokka", forward: false, matchCase: false)
        #expect(results(rig.delegate).last == FindResult(matchCount: cap, activeMatch: cap, isFinal: true))

        // What WebKit itself reports past the cap, read from a second delegate.
        do {
            let webView = try #require(tab.webView)
            WebKitSPI.setFindDelegate(webView, delegate)
            WebKitSPI.countMatches(webView, "quokka", options: [.caseInsensitive], maxCount: TabFinder.maxCount)
            try await waitUntil("the raw count", timeout: 5) { !raw.isEmpty }
            print("find: WebKit reported \(raw) for \(cap + 200) matches with maxCount \(cap)")
            #expect(raw.allSatisfy { $0 >= TabFinder.maxCount })
        }
        #expect(TabFinder.capped(UInt.max) == cap && TabFinder.capped(UInt(UInt32.max)) == cap)
        #expect(TabFinder.capped(3) == 3)
        try await rig.finish()
    }

    @Test func aClosedTabFindsNothing() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/find/plain.html")
        try await rig.waitFor("finish \(rig.url("/find/plain.html"))")
        #expect(await tab.close())
        rig.delegate.reset()
        tab.find("quokka", forward: true, matchCase: false)
        tab.stopFind()
        #expect(rig.delegate.events.isEmpty)
        try await rig.finish()
    }

    /// WebKit really calls the private find delegate's count and step callbacks, which nothing else checks: WebKit
    /// registers no `_WKFindDelegate` protocol to read.
    @Test func webKitCallsThePrivateFindCallbacks() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/find/plain.html")
        try await rig.waitFor("finish \(rig.url("/find/plain.html"))")
        let delegate = SPIFindDelegate()
        var counted: [UInt] = []
        var found: [UInt] = []
        delegate.onCount = { count, text in if text == "quokka" { counted.append(count) } }
        delegate.onFind = { count, text, _ in if text == "quokka" { found.append(count) } }
        do {
            let webView = try #require(tab.webView)
            #expect(WebKitSPI.setFindDelegate(webView, delegate))
            #expect(
                WebKitSPI.countMatches(webView, "quokka", options: [.caseInsensitive], maxCount: TabFinder.maxCount))
            try await waitUntil("didCountMatches", timeout: 5) { !counted.isEmpty }
            #expect(
                WebKitSPI.find(
                    webView, "quokka", options: [.caseInsensitive, .wrapAround, .determineMatchIndex],
                    maxCount: TabFinder.maxCount))
            try await waitUntil("didFindMatches", timeout: 5) { !found.isEmpty }
            #expect(counted == [4], "didCountMatches gave \(counted)")
            #expect(found.first == 4, "didFindMatches gave \(found)")
            WebKitSPI.setFindDelegate(webView, nil)
        }
        try await rig.finish()
    }
}
