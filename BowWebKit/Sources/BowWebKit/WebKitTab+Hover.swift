import AppKit
import BowCore
import WebKit

// The status text: the address of the link under the pointer, or "" once the pointer has left every link
// (`TabEvent.statusTextChanged`). WebKit's private hover callback reports the element under the pointer on every
// pointer move; where WebKit does not declare it, a script in Bow's own content world reports link changes instead
// (Scripts/HoverStatus.js). Each tab uses one source for the life of its web view, never both, so their reports
// cannot interleave, and sends the event only when the text changes.

/// A tab's status text and where it comes from.
struct HoverStatus {
    enum Source: Equatable {
        /// WebKit's private hover callback (`WebKitSPI.Callback.mouseDidMoveOverElement`).
        case callback
        /// The `mouseover` script, in Bow's hover content world.
        case script
    }

    /// The source of the web view installed last.
    var source: Source = .callback
    /// The text sent last.
    var text = ""
    /// Hover callbacks WebKit made, for the test that WebKit really calls it.
    var callbackCount = 0
}

extension WebKitTab {
    /// Test only: the profiles (`ObjectIdentifier` of a `WebKitProfile`) whose web views installed from now on get
    /// the script even where WebKit declares the callback, so the fallback is tested on every macOS. Per profile,
    /// so tests running beside it are untouched.
    static var hoverScriptProfiles: Set<ObjectIdentifier> = []

    /// The content world the hover script runs in, apart from the page's own scripts, which can neither see its
    /// message handler nor post to it.
    static let hoverWorld = WKContentWorld.world(name: "BowHoverStatus")
    static let hoverHandlerName = "bowHoverStatus"

    /// The hover script, a package resource read once.
    static let hoverScript: String? = {
        guard let url = Bundle.module.url(forResource: "HoverStatus", withExtension: "js", subdirectory: "Scripts")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// The source a new web view of the tab gets: the callback where WebKit declares it, the script otherwise.
    var hoverSource: HoverStatus.Source {
        !Self.hoverScriptProfiles.contains(ObjectIdentifier(profile))
            && WebKitSPI.isPresent(WebKitSPI.Callback.mouseDidMoveOverElement.entry) ? .callback : .script
    }

    /// Starts reporting the status text of `webView`, which the tab is installing.
    func observeHover(of webView: WKWebView) {
        hover.source = hoverSource
        onHoverLink = { [weak self] link, _ in
            guard let self, self.hover.source == .callback else { return }
            self.hover.callbackCount += 1
            self.hoverChanged(link?.absoluteString ?? "")
        }
        guard hover.source == .script else { return }
        guard let source = Self.hoverScript else {
            assertionFailure("Scripts/HoverStatus.js is missing from the BowWebKit bundle")
            return
        }
        // A content controller can be shared (WebKit gives a popup its opener's), and adding a handler name twice
        // raises, so a controller gets the handler and the script once; the relay finds each message's tab itself.
        let content = webView.configuration.userContentController
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        content.add(HoverScriptRelay(), contentWorld: Self.hoverWorld, name: Self.hoverHandlerName)
        content.addUserScript(
            WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.hoverWorld))
    }

    /// Sends `statusTextChanged` when `text` differs from the text sent last.
    func hoverChanged(_ text: String) {
        guard text != hover.text else { return }
        hover.text = text
        send(.statusTextChanged(text))
    }
}

/// Hands the hover script's messages to the tab of the web view that sent them: the tab that is its UI delegate
/// and has it installed now. It holds no tab, so the content controller, which keeps its handlers strongly, keeps
/// no tab alive, and a controller shared by several web views reaches each one's tab.
@MainActor
final class HoverScriptRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = webView.uiDelegate as? WebKitTab, webView === tab.webView,
            tab.hover.source == .script, let text = message.body as? String
        else { return }
        tab.hoverChanged(text)
    }
}
