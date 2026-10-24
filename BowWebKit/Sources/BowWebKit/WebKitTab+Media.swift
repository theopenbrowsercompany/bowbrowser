import BowCore
import WebKit

// The tab's sound and capture state: `EngineTabState.isAudible` from WebKit's private playing audio state, and
// `isCapturingVideo` and `isCapturingAudio` from the public camera and microphone capture states, each read by key
// value observation into the tab's state (WebKitTab+State.swift).

extension WebKitTab {
    /// Observes whether the page plays sound and whether it uses a camera or microphone. WebKit reports each change
    /// on the main thread.
    func observeMedia(of webView: WKWebView) {
        // Private: without it the tab never reports sound (WebKitSPI, `_isPlayingAudio`). Every tab's web view is a
        // WebKitWebView.
        // Observed only while WebKit has the key, since key value observation of a key WebKit dropped may raise.
        if let webView = webView as? WebKitWebView, WebKitWebView.hasPlayingAudioKey {
            observations.append(webView.observe(\.bowIsPlayingAudio) { [weak self] _, _ in self?.mediaDidChange() })
        }
        observations.append(webView.observe(\.cameraCaptureState) { [weak self] _, _ in self?.mediaDidChange() })
        observations.append(webView.observe(\.microphoneCaptureState) { [weak self] _, _ in self?.mediaDidChange() })
    }

    nonisolated private func mediaDidChange() {
        MainActor.assumeIsolated { refreshState() }
    }

    /// Reads the sound and capture state of `webView` into `state`.
    func readMedia(of webView: WKWebView, into state: inout EngineTabState) {
        state.isAudible = WebKitSPI.playingAudio(webView) ?? false
        state.isCapturingVideo = Self.isCapturing(webView.cameraCaptureState)
        state.isCapturingAudio = Self.isCapturing(webView.microphoneCaptureState)
    }

    /// A muted camera or microphone still counts: the page holds the device and can unmute it at any time.
    nonisolated static func isCapturing(_ state: WKMediaCaptureState) -> Bool {
        switch state {
        case .active, .muted: true
        case .none: false
        @unknown default: false
        }
    }
}

extension WebKitWebView {
    /// Whether the page plays sound, observable by key value observation: it changes whenever WebKit's private
    /// playing audio key does (see `keyPathsForValuesAffectingBowIsPlayingAudio`). False when WebKit lacks it.
    @objc dynamic var bowIsPlayingAudio: Bool { WebKitSPI.playingAudio(self) ?? false }

    /// The private key WebKit sends change notices for as the page starts and stops playing sound. Key value
    /// observation asks for it as an observation starts, which the tab does on the main thread.
    @objc nonisolated static func keyPathsForValuesAffectingBowIsPlayingAudio() -> Set<String> {
        MainActor.assumeIsolated { hasPlayingAudioKey ? [NSStringFromSelector(WebKitSPI.isPlayingAudio)] : [] }
    }

    /// Whether WebKit has its private playing audio key.
    static var hasPlayingAudioKey: Bool { WebKitSPI.has(WebKitSPI.isPlayingAudio, on: WKWebView.self) }
}
