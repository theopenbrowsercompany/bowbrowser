import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// The site icon: a page's icon link, `/favicon.ico` on its origin without one, and a change of the link in the
/// same document.
@Suite(.serialized) @MainActor struct FaviconTests {
    init() {
        TestHost.start()
    }

    private func lastFavicon(_ delegate: RecordingTabDelegate) -> URL?? {
        delegate.events.reversed().lazy.compactMap { if case .stateChanged(let s) = $0 { s.faviconURL } else { nil } }
            .first
    }

    /// Waits for the tab's icon to be `expected`, then checks the tab and its last state event both report it.
    private func expectFavicon(
        _ expected: URL, _ tab: WebKitTab, _ rig: TabRig, check: String
    ) async {
        // Waits on the value checked next; a timeout is reported by the check, with the icon seen.
        try? await waitUntil("faviconURL \(expected)", timeout: 5) { tab.state.faviconURL == expected }
        let ok = tab.state.faviconURL == expected && lastFavicon(rig.delegate) == .some(expected)
        #expect(ok, "\(check): faviconURL \(String(describing: tab.state.faviconURL)), expected \(expected)")
        print("\(ok ? "PASS" : "FAIL") pageSignals.favicon.\(check): \(tab.state.faviconURL?.absoluteString ?? "nil")")
    }

    @Test func iconLinkFallbackAndSameDocumentChange() async throws {
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
        let page = rig.url("/favicons/link.html")
        let tab = rig.tab("/favicons/link.html")
        try await rig.waitFor("finish \(page)")
        // The first link whose rel lists "icon", resolved against the page; the touch icon before it is not one.
        await expectFavicon(rig.url("/favicons/icon.png"), tab, rig, check: "link")

        // A same document change of the link moves the icon, and removing every icon link falls back.
        let driver = PageDriver(try #require(tab.webView))
        _ = try await driver.eval("document.querySelector('link[rel=\"shortcut icon\"]').href = 'changed.png'")
        await expectFavicon(rig.url("/favicons/changed.png"), tab, rig, check: "change")
        _ = try await driver.eval("for (const l of document.querySelectorAll('link[rel~=icon]')) l.remove()")
        await expectFavicon(rig.url("/favicon.ico"), tab, rig, check: "removed")

        // A page without an icon link has its origin's /favicon.ico.
        let none = rig.url("/favicons/none.html")
        tab.load(rig.url("/favicons/link.html"))
        await expectFavicon(rig.url("/favicons/icon.png"), tab, rig, check: "reload")
        tab.load(none)
        try await rig.waitFor("finish \(none)")
        await expectFavicon(rig.url("/favicon.ico"), tab, rig, check: "fallback")

        // Back to the page with the link, from the back and forward cache or afresh, reports its icon again.
        rig.delegate.reset()
        tab.goBack()
        try await rig.waitFor("commit \(page)")
        await expectFavicon(rig.url("/favicons/icon.png"), tab, rig, check: "back")
    }
}
