import WebKit

/// A navigation `DownloadResponder` turned into a download hands it to the profile's downloads, which keep it: the
/// tab never holds a download, so closing the tab leaves it running.
extension WebKitTab {
    nonisolated func webView(
        _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated { profile.webKitDownloads.adopt(download) }
    }

    nonisolated func webView(
        _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated { profile.webKitDownloads.adopt(download) }
    }
}
