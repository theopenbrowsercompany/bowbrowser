import BowCore
import WebKit

// Page zoom over WebKit's public `pageZoom`, which lays the page out again at the new size (unlike `magnification`,
// which only scales it). `pageZoom` belongs to one web view: remembering a zoom per site, so every tab on the site
// follows it, is Bow's per site zoom store's job, not the engine's.

extension WebKitTab {
    /// The page's zoom factor (1 is 100%); 100% once the tab is closed.
    var zoomFactor: Double { webView.map { Double($0.pageZoom) } ?? PageZoom.actualSize }

    /// Zooms the page to `factor`. Ignores a factor that is not a positive number, and a closed tab.
    func setZoomFactor(_ factor: Double) {
        guard let webView, factor.isFinite, factor > 0 else { return }
        webView.pageZoom = CGFloat(factor)
    }
}
