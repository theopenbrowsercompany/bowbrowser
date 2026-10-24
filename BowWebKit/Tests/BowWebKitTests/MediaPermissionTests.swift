import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// Camera and microphone requests reach the tab delegate's `decidePermission`, and its answer reaches the page (W1
/// criterion 6: a permission granted once is not asked again after the tab is made again).
@Suite(.serialized) @MainActor struct MediaPermissionTests {
    init() {
        TestHost.start()
    }

    /// A tab the profile makes, as the app makes one, on the permission page, answered by `delegate`, with mock
    /// capture devices on and shown.
    private func tab(_ rig: TabRig, delegate: PermissionStoreDelegate?) throws -> WebKitTab {
        let tab = try #require(rig.profile.createTab(url: rig.url("/permissions/media.html")) as? WebKitTab)
        try prepare(tab, rig, delegate: delegate)
        return tab
    }

    private func prepare(_ tab: WebKitTab, _ rig: TabRig, delegate: PermissionStoreDelegate?) throws {
        let webView = try #require(tab.webView)
        try MockCapture.enable(in: webView)
        WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false)
        tab.delegate = delegate
        rig.surface.show(tab)
    }

    private func waitForPage(_ tab: WebKitTab, _ rig: TabRig) async throws {
        let url = rig.url("/permissions/media.html")
        try await waitUntil("the permission page loaded, with its address and title", timeout: 10) {
            tab.state.url == url && !tab.state.isLoading && tab.state.title == "Media permission"
        }
    }

    /// Asks for the camera and microphone in the page: the live tracks it got (`audio:live`, `video:live`), or the
    /// error's name. Each call makes its own driver, so nothing here holds the web view afterwards.
    private func ask(_ tab: WebKitTab) async throws -> (tracks: [String], error: String?) {
        let value = try await PageDriver(try #require(tab.webView)).eval(
            """
            try {
              // Bounded, so a request no one answers fails the check instead of hanging the run.
              const unanswered = new Promise((_, reject) =>
                setTimeout(() => reject({ name: "unanswered after 10 s" }), 10000));
              const stream = await Promise.race([
                navigator.mediaDevices.getUserMedia({ video: true, audio: true }), unanswered]);
              const tracks = stream.getTracks().map(t => t.kind + ":" + t.readyState).sort();
              stream.getTracks().forEach(t => t.stop());
              return { tracks };
            } catch (e) {
              return { error: e.name };
            }
            """)
        let result = value as? [String: Any] ?? [:]
        return (result["tracks"] as? [String] ?? [], result["error"] as? String)
    }

    /// Closes `tab` and waits until its web view is released.
    private func close(_ tab: WebKitTab) async throws {
        let box = tab.webView.map(WeakBox.init)
        #expect(await tab.close())
        try await waitUntil("the closed tab's web view is released", timeout: 5) { box?.object == nil }
    }

    @Test func aGrantIsNotAskedAgainAfterTheTabIsMadeAgain() async throws {
        let rig = try TabRig()
        let authorization = MockCapture.systemAuthorization()
        let delegate = PermissionStoreDelegate()
        let site = try #require(URL(string: rig.server.base))
        let both = PermissionRequest(origin: site, kinds: [.camera, .microphone])
        let first = try tab(rig, delegate: delegate)
        try await waitForPage(first, rig)

        // The first ask reaches the delegate, which asks the person (here: Allow) and remembers the answer.
        let granted = try await ask(first)
        #expect(granted.tracks == ["audio:live", "video:live"] && granted.error == nil, "\(granted)")
        #expect(delegate.requests == [both])
        #expect(delegate.personAsks == [both])

        // Unloaded and made again from its session, as the app does with a tab it put to sleep.
        let box = first.webView.map(WeakBox.init)
        #expect(await first.unload())
        let session = try #require(first.sessionState)
        try await waitUntil("the unloaded tab's web view is released", timeout: 5) { box?.object == nil }
        let again = try #require(
            rig.profile.createTab(url: rig.url("/permissions/media.html"), restoring: session) as? WebKitTab)
        try prepare(again, rig, delegate: delegate)
        try await waitForPage(again, rig)

        // WebKit asks the new page's tab again; Bow's store answers, so the person is not asked a second time.
        let regranted = try await ask(again)
        #expect(regranted.tracks == ["audio:live", "video:live"] && regranted.error == nil, "\(regranted)")
        #expect(delegate.requests == [both, both])
        #expect(delegate.personAsks == [both])

        #expect(MockCapture.systemAuthorization() == authorization, "a request reached the system's devices")
        try await close(again)
        try await rig.finish()
    }

    @Test func aDenialOrDismissalGivesThePageNotAllowedError() async throws {
        let rig = try TabRig()
        let authorization = MockCapture.systemAuthorization()

        // Denied by the person, then by the store in the next tab without asking.
        let delegate = PermissionStoreDelegate()
        delegate.person = .deny
        for _ in 0..<2 {
            let tab = try tab(rig, delegate: delegate)
            try await waitForPage(tab, rig)
            let denied = try await ask(tab)
            #expect(denied.error == "NotAllowedError" && denied.tracks.isEmpty, "\(denied)")
            try await close(tab)
        }
        #expect(delegate.requests.count == 2)
        #expect(delegate.personAsks.count == 1)

        // A dismissal denies this page and remembers nothing, so the next page asks again.
        let dismissing = PermissionStoreDelegate()
        dismissing.person = .dismiss
        for _ in 0..<2 {
            let tab = try tab(rig, delegate: dismissing)
            try await waitForPage(tab, rig)
            let dismissed = try await ask(tab)
            #expect(dismissed.error == "NotAllowedError" && dismissed.tracks.isEmpty, "\(dismissed)")
            try await close(tab)
        }
        #expect(dismissing.personAsks.count == 2)

        // A tab no one answers for grants nothing.
        let alone = try tab(rig, delegate: nil)
        try await waitForPage(alone, rig)
        let unanswered = try await ask(alone)
        #expect(unanswered.error == "NotAllowedError" && unanswered.tracks.isEmpty, "\(unanswered)")
        try await close(alone)

        #expect(MockCapture.systemAuthorization() == authorization, "a request reached the system's devices")
        try await rig.finish()
    }

    @Test func aTabClosedWhileThePersonDecidesLetsItsPageGo() async throws {
        let rig = try TabRig()
        let delegate = PermissionStoreDelegate()
        delegate.person = nil
        let tab = try tab(rig, delegate: delegate)
        try await waitForPage(tab, rig)

        // Asked from the page without waiting for the outcome, since the page goes away before it comes: the script
        // returns at once, leaving the request open.
        // Scoped, so nothing here holds the web view once the tab closes.
        do {
            let webView = try #require(tab.webView)
            _ = try await webView.evaluateJavaScript(
                "navigator.mediaDevices.getUserMedia({ video: true, audio: true }).catch(() => {}); 0")
        }
        try await waitUntil("the request waits for the person", timeout: 10) {
            delegate.waiting == 1 && delegate.personAsks.count == 1
        }

        // The page is released while its request still waits, and the late answer grants nothing to anyone.
        try await close(tab)
        #expect(delegate.waiting == 1)
        delegate.answerWaiting(.allow)
        #expect(delegate.waiting == 0)
        try await rig.finish()
    }

    @Test func webKitOriginsAndCaptureTypesBecomeBowRequests() {
        #expect(
            WebKitTab.originURL(scheme: "http", host: "127.0.0.1", port: 8080)?.absoluteString
                == "http://127.0.0.1:8080")
        #expect(
            WebKitTab.originURL(scheme: "https", host: "meet.example.com", port: 0)?.absoluteString
                == "https://meet.example.com")
        #expect(WebKitTab.originURL(scheme: "http", host: "::1", port: 8080)?.absoluteString == "http://[::1]:8080")
        // An opaque origin (a sandboxed frame, a data: page) has no site, so Bow always asks.
        #expect(WebKitTab.originURL(scheme: "", host: "", port: 0) == nil)
        #expect(
            WebKitTab.originURL(scheme: "https", host: "meet.example.com", port: 0).flatMap(PermissionSite.init)
                == PermissionSite(url: URL(string: "https://meet.example.com")!))

        #expect(WebKitTab.permissionKinds(of: .camera) == [.camera])
        #expect(WebKitTab.permissionKinds(of: .microphone) == [.microphone])
        #expect(WebKitTab.permissionKinds(of: .cameraAndMicrophone) == [.camera, .microphone])

        #expect(WebKitTab.mediaDecision(for: .allow) == .grant)
        #expect(WebKitTab.mediaDecision(for: .deny) == .deny)
        #expect(WebKitTab.mediaDecision(for: .dismiss) == .deny)
    }
}

/// A tab delegate that answers permission requests as the app does: from a profile's `SitePermissionStore` when it
/// remembers an answer, otherwise by asking the person (`person`, or held until `answerWaiting` when nil) and
/// recording their answer.
@MainActor
final class PermissionStoreDelegate: EngineTabDelegate {
    let store = SitePermissionStore(fileURL: nil)
    /// What the person answers; nil holds each request until `answerWaiting(_:)`.
    var person: PermissionDecision? = .allow
    /// Every request the tab handed over, in order.
    private(set) var requests: [PermissionRequest] = []
    /// The requests the store had no answer for, so the person was asked.
    private(set) var personAsks: [PermissionRequest] = []
    private var held: [CheckedContinuation<PermissionDecision, Never>] = []

    var waiting: Int { held.count }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {}

    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        requests.append(request)
        if let remembered = store.decision(for: request) { return remembered }
        personAsks.append(request)
        let decision: PermissionDecision
        if let person {
            decision = person
        } else {
            decision = await withCheckedContinuation { held.append($0) }
        }
        _ = try? store.record(decision, for: request)
        return decision
    }

    /// The person answers every held request with `decision`.
    func answerWaiting(_ decision: PermissionDecision) {
        let answering = held
        held = []
        for answer in answering { answer.resume(returning: decision) }
    }
}
