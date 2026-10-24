import AppKit
import BowCore
import Darwin
import Testing
import WebKit

@testable import BowWebKit

/// A page's web content process ending reaches the tab as one `renderProcessGone` with WebKit's reason, through
/// WebKit's private reason callback, and the page loads again on reload.
@Suite(.serialized) @MainActor struct ProcessGoneTests {
    init() {
        TestHost.start()
    }

    nonisolated private static let page = "<!doctype html><title>Alive</title><p>alive</p>"

    private func gone(_ delegate: RecordingTabDelegate) -> [ProcessGoneReason] {
        delegate.events.compactMap { if case .renderProcessGone(let reason) = $0 { reason } else { nil } }
    }

    /// The process a tab's page runs in.
    private func pid(_ tab: WebKitTab) throws -> pid_t {
        let webView = try #require(tab.webView)
        return try #require(WebKitSPI.processIdentifier(webView), "no web content process")
    }

    @Test func killedProcessIsReportedOnceAndReloadBringsThePageBack() async throws {
        let rig = try TabRig()
        rig.server.route("/alive") { _ in .html(Self.page) }
        let alive = rig.url("/alive")
        let tab = rig.tab("/alive")
        try await rig.waitFor("finish \(alive)")
        try await waitUntil("the page title", timeout: 10) { tab.state.title == "Alive" && !tab.state.isLoading }
        let before = try pid(tab)

        // Killed from outside, as the system or Activity Monitor would. WebKit's own `_killWebContentProcess` is
        // not used: in a process without WebKit's private entitlements it returns and leaves the process running
        // (found here on macOS 26: no termination after 30 s).
        rig.delegate.reset()
        #expect(kill(before, SIGKILL) == 0, "could not end the page's process \(before)")
        let reason = try await waitFor("renderProcessGone; saw \(rig.delegate.events)", timeout: 10) {
            gone(rig.delegate).first
        }
        // WebKit reports a process ended by a signal as a crash: it cannot tell a kill from one. The public callback
        // alone would say `.other`, so this reason came through the private callback.
        #expect(reason == .crashed)
        // The page is blank and keeps its address and history.
        #expect(tab.state.url == alive && !tab.isClosed && !tab.state.isLoading)
        #expect(WebKitSPI.processIdentifier(try #require(tab.webView)) == nil)

        tab.reload()
        try await rig.waitFor("finish \(alive)")
        try await waitUntil("the reloaded page in a new process", timeout: 10) {
            try await PageDriver(tab.webView!).string("return document.title") == "Alive"
                && WebKitSPI.processIdentifier(tab.webView!).map { $0 != before } == true
        }
        // One load before the kill and the app's reload: WebKit did not reload the page by itself.
        #expect(rig.server.count(path: "/alive") == 2, "requests: \(rig.server.count(path: "/alive"))")
        #expect(gone(rig.delegate) == [.crashed], "renderProcessGone came again: \(gone(rig.delegate))")
        #expect(tab.state.url == alive && tab.state.title == "Alive")
        try await rig.finish()
    }

    /// A process killed from outside (as Activity Monitor or the system would) while a navigation is under way: the
    /// navigation fails as aborted before the tab hears the process is gone, and nothing follows for it.
    @Test func processKilledFromOutsideMidNavigation() async throws {
        let rig = try TabRig()
        rig.server.route("/alive") { _ in .html(Self.page) }
        rig.server.route("/slow") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
        let alive = rig.url("/alive")
        let slow = rig.url("/slow")
        let tab = rig.tab("/alive")
        try await rig.waitFor("finish \(alive)")
        let process = try pid(tab)
        tab.load(slow)
        try await rig.waitFor("start \(slow)")

        rig.delegate.reset()
        #expect(kill(process, SIGKILL) == 0, "could not end the page's process \(process)")
        let reason = try await waitFor("renderProcessGone; saw \(rig.delegate.events)", timeout: 10) {
            gone(rig.delegate).first
        }
        #expect(reason == .crashed)
        let failure = rig.delegate.events.firstIndex {
            if case .didFail(let n, let error) = $0 { n.url == slow && error.reason == .aborted } else { false }
        }
        let goneAt = rig.delegate.events.firstIndex { $0 == .renderProcessGone(reason) }
        #expect(failure != nil && goneAt != nil && failure! < goneAt!, "events: \(rig.delegate.events)")
        #expect(rig.delegate.navigation == ["fail \(slow)"])
        #expect(!tab.state.isLoading && tab.state.url == alive)

        tab.load(alive)
        try await rig.waitFor("finish \(alive)")
        #expect(gone(rig.delegate).count == 1)
        try await rig.finish()
    }

    /// A tab answers WebKit's private reason callback, so WebKit calls it rather than the public one.
    @Test func tabAnswersThePrivateReasonCallback() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/navigation/start.html", shown: false)
        #expect(tab.responds(to: WebKitSPI.Callback.processTerminated.selector))
        try await rig.finish()
    }

    @Test func reasonsMapToTheContract() {
        #expect(ProcessGoneReason(.crash) == .crashed)
        #expect(ProcessGoneReason(.requestedByClient) == .requestedByApp)
        #expect(ProcessGoneReason(.exceededMemoryLimit) == .outOfMemory)
        #expect(ProcessGoneReason(.exceededCPULimit) == .exceededCPULimit)
        #expect(ProcessGoneReason(nil) == .other)
        #expect(SPIProcessTerminationReason(rawValue: 9) == nil)
    }
}
