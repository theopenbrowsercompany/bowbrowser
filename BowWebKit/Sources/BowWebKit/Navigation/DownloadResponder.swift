import BowCore
import Foundation
import WebKit

/// Turns into downloads what the page asks to download and what WebKit cannot show: a link or script that asks for
/// a download (the `download` attribute), and a response the server sends as an attachment or of a type no frame
/// can show. The profile's downloads take each one (`WebKitTab+Downloads.swift`); one they refuse (no delegate to
/// choose its destination, or the delegate says no) is cancelled and sends no download event.
///
/// A response that becomes a download ends its navigation, which the tab reports as a failure (aborted), as the
/// contract says of a download; the page stays as it was.
@MainActor
final class DownloadResponder: NavigationResponder {
    func decidePolicy(for action: WKNavigationAction, in tab: WebKitTab) -> WKNavigationActionPolicy? {
        guard action.shouldPerformDownload, let url = action.request.url else { return nil }
        return tab.profile.webKitDownloads.accepts(url) ? .download : .cancel
    }

    func decidePolicy(for response: WKNavigationResponse, in tab: WebKitTab) -> WKNavigationResponsePolicy? {
        guard Self.isDownload(response), let url = response.response.url else { return nil }
        return tab.profile.webKitDownloads.accepts(url) ? .download : .cancel
    }

    /// An attachment (`Content-Disposition: attachment`, as Chromium reads it), or a type WebKit cannot show.
    static func isDownload(_ response: WKNavigationResponse) -> Bool {
        if let http = response.response as? HTTPURLResponse,
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
            disposition.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "attachment"
        {
            return true
        }
        return !response.canShowMIMEType
    }
}
