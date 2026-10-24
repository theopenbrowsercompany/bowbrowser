import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab reports when its page plays sound and when it uses a camera or microphone, as state changes.
@Suite(.serialized) @MainActor struct MediaStateTests {
    init() {
        TestHost.start()
    }

    /// A tab of `rig`'s profile on a web view whose configuration `configure` changed first (the profile's own
    /// configuration is the product's; tests add autoplay and mock devices to it), loading `path`, shown.
    private func tab(
        _ rig: TabRig, _ path: String, configure: (WKWebViewConfiguration) throws -> Void
    ) rethrows -> WebKitTab {
        let tab = WebKitTab(profile: rig.profile)
        tab.releaseWebView()
        let configuration = rig.profile.makeConfiguration()
        try configure(configuration)
        let webView = WebKitWebView(frame: .zero, configuration: configuration)
        WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false)
        tab.install(webView)
        tab.delegate = rig.delegate
        rig.surface.show(tab)
        tab.load(rig.url(path))
        return tab
    }

    /// Closes `tab` and checks its web view is released, then finishes the rig.
    private func finish(_ tab: WebKitTab, _ rig: TabRig) async throws {
        let box = tab.webView.map(WeakBox.init)
        _ = await tab.close()
        try await rig.finish()
        try await waitUntil("the web view is released", timeout: 5) { box?.object == nil }
    }

    private func states(_ delegate: RecordingTabDelegate) -> [EngineTabState] {
        delegate.events.compactMap { if case .stateChanged(let s) = $0 { s } else { nil } }
    }

    @Test func playingSoundTurnsAudibleOnAndPausingTurnsItOff() async throws {
        let rig = try TabRig()
        let url = rig.url("/media/audio.html")
        let tab = tab(rig, "/media/audio.html") { $0.mediaTypesRequiringUserActionForPlayback = [] }
        try await waitUntil("the audio page loaded", timeout: 10) {
            tab.state.url == url && !tab.state.isLoading && tab.state.title == "Audio"
        }
        #expect(!tab.state.isAudible)

        _ = try await PageDriver(tab.webView!).eval("await document.getElementById('tone').play(); return true")
        try await waitUntil("a stateChanged with isAudible", timeout: 10) {
            states(rig.delegate).last?.isAudible == true && tab.state.isAudible
        }
        #expect(try await PageDriver(tab.webView!).bool("return !document.getElementById('tone').paused"))

        _ = try await PageDriver(tab.webView!).eval("document.getElementById('tone').pause(); return true")
        try await waitUntil("a stateChanged with isAudible off", timeout: 10) {
            states(rig.delegate).last?.isAudible == false && !tab.state.isAudible
        }
        try await finish(tab, rig)
    }

    @Test func capturingTurnsCameraAndMicrophoneOnAndStoppingTurnsThemOff() async throws {
        let rig = try TabRig()
        let url = rig.url("/media/capture.html")
        let grant = GrantCapture()
        let tab = try tab(rig, "/media/capture.html") { configuration in
            // Mock devices only: a test never opens a real camera or microphone, or asks the person.
            try #require(
                WebKitSPI.setMockCaptureDevicesEnabled(configuration.preferences, true),
                "no mock capture devices on this macOS; the check is skipped rather than use a real device")
        }
        // Capture permission is the permissions area's to answer; here the test grants it.
        tab.webView?.uiDelegate = grant
        try await waitUntil("the capture page loaded", timeout: 10) {
            tab.state.url == url && !tab.state.isLoading && tab.state.title == "Capture"
        }
        #expect(!tab.state.isCapturingVideo && !tab.state.isCapturingAudio)

        let tracks = try await PageDriver(tab.webView!).eval(
            """
            window.bowTestStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
            return window.bowTestStream.getTracks().map(t => t.kind).sort();
            """)
        #expect(tracks as? [String] == ["audio", "video"])
        try await waitUntil("a stateChanged with the camera and microphone on", timeout: 10) {
            let last = states(rig.delegate).last
            return last?.isCapturingVideo == true && last?.isCapturingAudio == true && tab.state.isCapturingVideo
                && tab.state.isCapturingAudio
        }
        #expect(grant.asked.sorted() == ["cameraAndMicrophone"])

        _ = try await PageDriver(tab.webView!).eval("window.bowTestStream.getTracks().forEach(t => t.stop()); return true")
        try await waitUntil("a stateChanged with the camera and microphone off", timeout: 10) {
            let last = states(rig.delegate).last
            return last?.isCapturingVideo == false && last?.isCapturingAudio == false && !tab.state.isCapturingVideo
                && !tab.state.isCapturingAudio
        }
        tab.webView?.uiDelegate = tab
        try await finish(tab, rig)
    }

    @Test func aMutedDeviceStillCounts() {
        #expect(WebKitTab.isCapturing(.active))
        #expect(WebKitTab.isCapturing(.muted))
        #expect(!WebKitTab.isCapturing(.none))
    }
}

/// Grants every camera and microphone request of the page, recording which it was asked.
@MainActor
final class GrantCapture: NSObject, WKUIDelegate {
    private(set) var asked: [String] = []

    nonisolated func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        MainActor.assumeIsolated {
            switch type {
            case .camera: asked.append("camera")
            case .microphone: asked.append("microphone")
            case .cameraAndMicrophone: asked.append("cameraAndMicrophone")
            @unknown default: asked.append("other")
            }
            decisionHandler(.grant)
        }
    }
}
