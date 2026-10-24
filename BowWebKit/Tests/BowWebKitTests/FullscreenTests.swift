import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab sends `fullscreenChanged` as its page enters and leaves fullscreen, and `exitFullscreen` asks it to leave.
///
/// No test enters real fullscreen: WebKit moves a fullscreen element into a window of its own on a screen, which a
/// test must never show. So these drive the tab's fullscreen state handler, which the key value observation of
/// `fullscreenState` calls, with each state WebKit reports.
@Suite(.serialized) @MainActor struct FullscreenTests {
    init() {
        TestHost.start()
    }

    private func fullscreenEvents(_ delegate: RecordingTabDelegate) -> [Bool] {
        delegate.events.compactMap { if case .fullscreenChanged(let on) = $0 { on } else { nil } }
    }

    @Test func enteringAndLeavingSendsOneChangeEach() async throws {
        let rig = try TabRig()
        let a = rig.url("/navigation/a.html")
        let tab = rig.tab("/navigation/a.html")
        try await waitUntil("a loaded", timeout: 10) {
            tab.state.url == a && !tab.state.isLoading && tab.state.title == "A"
        }
        #expect(tab.webView?.fullscreenState == .notInFullscreen)
        #expect(fullscreenEvents(rig.delegate).isEmpty)
        // The page may go fullscreen: the tab turned element fullscreen on as it observed the page.
        #expect(try await PageDriver(tab.webView!).bool("return document.fullscreenEnabled"))
        let tracker = FullscreenTracker()

        // In: entering changes nothing, in fullscreen sends true once.
        tab.fullscreenStateDidChange(to: .enteringFullscreen, tracker)
        #expect(fullscreenEvents(rig.delegate).isEmpty)
        tab.fullscreenStateDidChange(to: .inFullscreen, tracker)
        tab.fullscreenStateDidChange(to: .inFullscreen, tracker)
        #expect(fullscreenEvents(rig.delegate) == [true])

        // Out: exiting changes nothing, out of fullscreen sends false once.
        tab.fullscreenStateDidChange(to: .exitingFullscreen, tracker)
        #expect(fullscreenEvents(rig.delegate) == [true])
        tab.fullscreenStateDidChange(to: .notInFullscreen, tracker)
        tab.fullscreenStateDidChange(to: .notInFullscreen, tracker)
        #expect(fullscreenEvents(rig.delegate) == [true, false])

        // An entry that falls back out sends nothing.
        tab.fullscreenStateDidChange(to: .enteringFullscreen, tracker)
        tab.fullscreenStateDidChange(to: .notInFullscreen, tracker)
        #expect(fullscreenEvents(rig.delegate) == [true, false])
        try await rig.finish()
    }

    @Test func exitFullscreenOutOfFullscreenDoesNothing() async throws {
        let rig = try TabRig()
        let a = rig.url("/navigation/a.html")
        let tab = rig.tab("/navigation/a.html")
        try await waitUntil("a loaded", timeout: 10) {
            tab.state.url == a && !tab.state.isLoading && tab.state.title == "A"
        }
        rig.delegate.reset()
        tab.exitFullscreen()
        #expect(tab.webView?.fullscreenState == .notInFullscreen)
        #expect(fullscreenEvents(rig.delegate).isEmpty)
        // The page is still there and answers.
        #expect(try await PageDriver(tab.webView!).string("return document.title") == "A")
        _ = await tab.close()
        tab.exitFullscreen()
        #expect(fullscreenEvents(rig.delegate).isEmpty)
        try await rig.finish()
    }
}
