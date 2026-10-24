import BowCore
import Foundation
import WebKit

/// Camera and microphone. WebKit asks the tab each time a page calls `getUserMedia` without a grant for its document
/// (a new page, a reload, a tab made again from its session), and the tab hands the request to its delegate's
/// `decidePermission`, which answers from Bow's per profile store or asks the person. WebKit's own prompt never
/// shows, and WebKit keeps no answer across pages, so Bow's store is the only record (see
/// `WebKitProfile.setPermission`).
extension WebKitTab {
    nonisolated func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        MainActor.assumeIsolated {
            let request = PermissionRequest(
                origin: Self.originURL(scheme: origin.protocol, host: origin.host, port: origin.port),
                kinds: Self.permissionKinds(of: type))
            // A page the tab let go, or a tab no one answers for, gets nothing.
            guard webView === self.webView, let delegate else { return decisionHandler(.deny) }
            Task { @MainActor [weak self, weak webView] in
                guard let self else { return decisionHandler(.deny) }
                let decision = await delegate.tab(self, decidePermission: request)
                // The page may have gone while the person answered (the tab closed or unloaded): it gets nothing.
                let isSamePage = webView != nil && webView === self.webView
                decisionHandler(isSamePage ? Self.mediaDecision(for: decision) : .deny)
            }
        }
    }

    /// What WebKit's capture type asks for.
    nonisolated static func permissionKinds(of type: WKMediaCaptureType) -> Set<PermissionKind> {
        switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.other]
        }
    }

    /// WebKit's answer for Bow's: only an allow grants. A dismissal denies this request too, since WebKit's other
    /// answer (`prompt`) would show its own prompt; Bow remembers nothing for it, so the next page asks again.
    nonisolated static func mediaDecision(for decision: PermissionDecision) -> WKPermissionDecision {
        decision == .allow ? .grant : .deny
    }

    /// The origin WebKit reports (`WKSecurityOrigin`: its scheme, its host, and its port or 0 for the scheme's
    /// default) as a URL, or nil for an opaque origin (a sandboxed frame or a `data:` page), which has no site.
    nonisolated static func originURL(scheme: String, host: String, port: Int) -> URL? {
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(hostPart)" + (port == 0 ? "" : ":\(port)"))
    }
}
