import BowCore
import WebKit

// What the page tells Bow about itself without being asked: whether the person edited one of its form fields
// (`EngineTabState.hasEditedForm`, Scripts/EditedForm.js) and the address of its site icon
// (`EngineTabState.faviconURL`, Scripts/Favicon.js). Both scripts run in Bow's own content world, apart from the
// page's scripts, which can neither see them nor post to their message handler. A new main frame document clears
// the edited signal as it commits; the icon stays until the new document reports its own.

extension WebKitTab {
    /// The content world the page signal scripts run in.
    static let pageSignalsWorld = WKContentWorld.world(name: "BowPageSignals")
    static let pageSignalsHandlerName = "bowPageSignals"

    /// A package script, read once.
    private static func script(_ name: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Scripts") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let editedFormScript = script("EditedForm")
    static let faviconScript = script("Favicon")

    /// Starts reading the page signals of `webView`, which the tab is installing.
    func observePageSignals(of webView: WKWebView) {
        guard let edited = Self.editedFormScript, let favicon = Self.faviconScript else {
            assertionFailure("Scripts/EditedForm.js or Scripts/Favicon.js is missing from the BowWebKit bundle")
            return
        }
        // A content controller can be shared (WebKit gives a popup its opener's), and adding a handler name twice
        // raises, so a controller gets the handler and the scripts once; the relay finds each message's tab itself.
        let content = webView.configuration.userContentController
        guard !content.userScripts.contains(where: { $0.source == edited }) else { return }
        content.add(PageSignalsRelay(), contentWorld: Self.pageSignalsWorld, name: Self.pageSignalsHandlerName)
        content.addUserScript(
            WKUserScript(
                source: edited, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.pageSignalsWorld))
        content.addUserScript(
            WKUserScript(
                source: favicon, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.pageSignalsWorld))
    }

    /// Applies `change` to the page signals of the state and sends `stateChanged` when the state differs.
    func updatePageSignals(_ change: (inout EngineTabState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        send(.stateChanged(next))
    }
}

/// Hands the page signal scripts' messages to the tab of the web view that sent them: the tab that is its UI
/// delegate and has it installed now. It holds no tab, so the content controller, which keeps its handlers
/// strongly, keeps no tab alive, and a controller shared by several web views reaches each one's tab.
@MainActor
final class PageSignalsRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = webView.uiDelegate as? WebKitTab, webView === tab.webView,
            let body = message.body as? [String: Any], let kind = body["kind"] as? String
        else { return }
        switch kind {
        case "edited":
            tab.updatePageSignals { $0.hasEditedForm = true }
        case "favicon":
            // Only the main frame's document has the tab's icon.
            guard message.frameInfo.isMainFrame else { return }
            let url = (body["url"] as? String).flatMap(URL.init(string:))
            tab.updatePageSignals { $0.faviconURL = url }
        default:
            return
        }
    }
}

/// Clears the edited signal when a new main frame document commits, before the app hears of the commit.
@MainActor
final class PageSignalsResponder: NavigationResponder {
    func didCommit(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {
        tab.updatePageSignals { $0.hasEditedForm = false }
    }
}
