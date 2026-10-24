import AVFoundation
import Testing
import WebKit

@testable import BowWebKit

/// WebKit's mock camera and microphone for tests that capture: a test never opens a real device, or makes macOS ask
/// the person (the test process has no usage description). Turn them on before the page's first `getUserMedia`.
@MainActor
enum MockCapture {
    /// Turns mock devices on in `preferences`, for a configuration a web view is about to be made with. Fails the
    /// test when this macOS has no mock devices, rather than use a real one.
    static func enable(_ preferences: WKPreferences) throws {
        try #require(
            WebKitSPI.setMockCaptureDevicesEnabled(preferences, true),
            "no mock capture devices on this macOS; the check fails rather than use a real device")
    }

    /// Turns mock devices on for the page of `webView`, made already (a tab the profile made, which tests do not
    /// configure). A web view's `configuration` is a copy each time, but it shares the page's own live preferences,
    /// which WebKit reads at each capture request; checked here, so a WebKit that stopped sharing them fails before
    /// any capture rather than reach a real device.
    static func enable(in webView: WKWebView) throws {
        let preferences = webView.configuration.preferences
        try #require(
            preferences === webView.configuration.preferences,
            "the web view's preferences are no longer its page's live ones; mock devices cannot be turned on")
        try enable(preferences)
    }

    /// The system's camera and microphone authorization for this process, which no test may change: read before and
    /// after capturing, so a request that reached a real device fails the test.
    static func systemAuthorization() -> [AVAuthorizationStatus] {
        [AVCaptureDevice.authorizationStatus(for: .video), AVCaptureDevice.authorizationStatus(for: .audio)]
    }
}

/// Grants every camera and microphone request of the page, recording which it was asked: a UI delegate for tests
/// whose page captures but that do not test the permission itself.
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
