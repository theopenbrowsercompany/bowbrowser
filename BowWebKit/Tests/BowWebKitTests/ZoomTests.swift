import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab's zoom factor is its web view's page zoom, and the page lays out at the new size.
@Suite(.serialized) @MainActor struct ZoomTests {
    init() {
        TestHost.start()
    }

    @Test func zoomFactorSetsPageZoomAndThePageLaysOutSmaller() async throws {
        let rig = try TabRig()
        let a = rig.url("/navigation/a.html")
        let tab = rig.tab("/navigation/a.html")
        try await waitUntil("a loaded", timeout: 10) {
            tab.state.url == a && !tab.state.isLoading && tab.state.title == "A"
        }
        let webView = try #require(tab.webView)
        let page = PageDriver(webView)
        #expect(tab.zoomFactor == PageZoom.actualSize)
        let width = try await page.number("return window.innerWidth")
        #expect(width > 0)

        tab.setZoomFactor(1.5)
        #expect(webView.pageZoom == 1.5)
        #expect(PageZoom.percent(forFactor: tab.zoomFactor) == 150)
        // The page's CSS pixel width shrinks by the factor once WebKit lays it out again.
        try await waitUntil("the page at 150%", timeout: 10) {
            abs(try await page.number("return window.innerWidth") - width / 1.5) <= 1
        }

        // A factor that is no size is ignored.
        tab.setZoomFactor(0)
        tab.setZoomFactor(-1)
        tab.setZoomFactor(.nan)
        #expect(webView.pageZoom == 1.5)

        tab.setZoomFactor(PageZoom.actualSize)
        try await waitUntil("the page at 100%", timeout: 10) {
            abs(try await page.number("return window.innerWidth") - width) <= 1
        }
        #expect(tab.zoomFactor == PageZoom.actualSize)

        _ = await tab.close()
        #expect(tab.zoomFactor == PageZoom.actualSize)
        tab.setZoomFactor(2)
        try await rig.finish()
    }
}
