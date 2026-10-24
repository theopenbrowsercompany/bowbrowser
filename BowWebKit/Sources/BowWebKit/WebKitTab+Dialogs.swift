import BowCore
import WebKit

// A page's alert, confirm and prompt panels, answered by the tab's delegate (`EngineTabDelegate.tab(_:runDialog:)`),
// which may take as long as the person needs. With no delegate the dialog is cancelled. WebKit requires each panel's
// completion handler to be called exactly once: a reply answers once, and the web view cancels every panel still open
// when its tab lets the page go (closing, unloading), so a late answer from the delegate does nothing.

/// One open panel's answer to the page, given once.
@MainActor
final class PageDialogReply {
    private var complete: ((PageDialogAnswer) -> Void)?

    init(_ complete: @escaping (PageDialogAnswer) -> Void) {
        self.complete = complete
    }

    /// Answers the page; every later call does nothing.
    func answer(_ answer: PageDialogAnswer) {
        guard let complete else { return }
        self.complete = nil
        complete(answer)
    }
}

extension WebKitTab {
    nonisolated func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        MainActor.assumeIsolated {
            runDialog(.alert, message: message, defaultText: nil, frame: frame, in: webView) { _ in completionHandler()
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            runDialog(.confirm, message: message, defaultText: nil, frame: frame, in: webView) {
                completionHandler($0.accepted)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        MainActor.assumeIsolated {
            runDialog(.prompt, message: prompt, defaultText: defaultText, frame: frame, in: webView) {
                // OK with an empty field gives the page an empty string, Cancel gives null.
                completionHandler($0.accepted ? ($0.text ?? "") : nil)
            }
        }
    }

    /// Asks the delegate about the panel and answers the page once, or cancels it at once when the panel comes from
    /// a page the tab no longer shows or the tab has no delegate.
    private func runDialog(
        _ kind: PageDialogKind, message: String, defaultText: String?, frame: WKFrameInfo, in webView: WKWebView,
        complete: @escaping (PageDialogAnswer) -> Void
    ) {
        guard let page = webView as? WebKitWebView, page === self.webView, delegate != nil else {
            return complete(.cancelled)
        }
        let reply = PageDialogReply(complete)
        let key = ObjectIdentifier(reply)
        page.openDialogs[key] = reply
        let dialog = PageDialog(
            kind: kind, origin: Self.originURL(frame.securityOrigin), message: message,
            defaultPromptText: kind == .prompt ? (defaultText ?? "") : "")
        Task { @MainActor [weak self, weak page] in
            var answer = PageDialogAnswer.cancelled
            if let self, let delegate = self.delegate {
                answer = await delegate.tab(self, runDialog: dialog)
            }
            page?.openDialogs[key] = nil
            reply.answer(answer)
        }
    }

    /// The address of a frame's origin: scheme, host and a port other than the scheme's default (WebKit gives 0 for
    /// that); nil for an origin with no host (a file or `data:` page).
    static func originURL(_ origin: WKSecurityOrigin) -> URL? {
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        return components.url
    }
}
