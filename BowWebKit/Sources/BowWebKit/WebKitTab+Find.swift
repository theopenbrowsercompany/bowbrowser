import BowCore
import WebKit

extension WebKitTab {
    func find(_ text: String, forward: Bool, matchCase: Bool) {
        finder.find(text, forward: forward, matchCase: matchCase)
    }

    func stopFind() {
        finder.stop()
    }
}

/// Find in page for one tab. Through WebKit's private find (`WebKitSPI`) it counts the matches and steps through
/// them, and BowCore's `FindMatchTracker` decides what each request does and which match is active, since WebKit's
/// own index cannot be trusted. Without the private find it falls back to the public `find(_:configuration:)`,
/// which only says whether a match was found (an approximate result: see `approximate(found:)`).
@MainActor
final class TabFinder {
    /// The most matches WebKit counts, as Safari does.
    static let maxCount: UInt = 1000
    /// Options of every step: wrap at either end, show the active match and highlight the rest.
    static let stepOptions: WebKitSPI.FindOptions = [.wrapAround, .showFindIndicator, .showHighlight]

    private weak var tab: WebKitTab?
    private var tracker = FindMatchTracker()
    /// WebKit holds its find delegate weakly; this keeps it for the tab's life.
    private let spiDelegate = SPIFindDelegate()
    /// Tests only: use the public find even where the private one is present.
    var forcesPublicFind = false
    /// Bumped by every public find and every stop, so only the newest public answer is sent.
    private var publicGeneration = 0

    init(tab: WebKitTab) {
        self.tab = tab
        spiDelegate.onCount = { [weak self] count, text in self?.counted(text, Self.capped(count)) }
    }

    /// WebKit reports more than `maxCount` matches as a sentinel (an all ones count), which shows as `maxCount`.
    static func capped(_ count: UInt) -> Int {
        Int(min(count, maxCount))
    }

    /// `EngineTab.find(_:forward:matchCase:)`.
    func find(_ text: String, forward: Bool, matchCase: Bool) {
        guard let tab, !tab.isClosed, let webView = tab.webView else { return }
        guard !forcesPublicFind, hasPrivateFind(webView), WebKitSPI.setFindDelegate(webView, spiDelegate) else {
            return publicFind(text, forward: forward, matchCase: matchCase, in: webView)
        }
        let update = tracker.find(text, forward: forward, matchCase: matchCase)
        let caseOption: WebKitSPI.FindOptions = matchCase ? [] : [.caseInsensitive]
        switch update.action {
        case .startSearch(let text, _):
            WebKitSPI.countMatches(webView, text, options: caseOption, maxCount: Self.maxCount)
            WebKitSPI.find(webView, text, options: caseOption.union(Self.stepOptions), maxCount: Self.maxCount)
        case .step(let forward):
            let direction: WebKitSPI.FindOptions = forward ? [] : [.backwards]
            WebKitSPI.find(
                webView, text, options: caseOption.union(Self.stepOptions).union(direction), maxCount: Self.maxCount)
        case .stop:
            WebKitSPI.hideFind(webView)
        }
        if let result = update.result { tab.send(.findResult(result)) }
    }

    /// `EngineTab.stopFind()`: clears the highlight and drops results of the search that arrive later; the active
    /// match stays selected.
    func stop() {
        publicGeneration += 1
        let update = tracker.find("", forward: true, matchCase: false)
        guard update.action == .stop, let webView = tab?.webView else { return }
        WebKitSPI.hideFind(webView)
    }

    /// The tab committed a new main frame document: the next find counts again and starts at 1.
    func pageChanged() {
        tracker.pageChanged()
    }

    private func hasPrivateFind(_ webView: WKWebView) -> Bool {
        webView.responds(to: WebKitSPI.findString) && webView.responds(to: WebKitSPI.countStringMatches)
    }

    private func counted(_ text: String, _ count: Int) {
        guard let tab, !tab.isClosed, let result = tracker.counted(text: text, count: count) else { return }
        tab.send(.findResult(result))
    }

    // MARK: The public fallback

    /// What the public find's answer reports: found is "at least one, still counting" (1 of 1, never final), and
    /// not found is a final 0 of 0. The public API gives no count and no index.
    static func approximate(found: Bool) -> FindResult {
        found
            ? FindResult(matchCount: 1, activeMatch: 1, isFinal: false)
            : FindResult(matchCount: 0, activeMatch: 0, isFinal: true)
    }

    private func publicFind(_ text: String, forward: Bool, matchCase: Bool, in webView: WKWebView) {
        publicGeneration += 1
        guard !text.isEmpty else { return }
        let generation = publicGeneration
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = matchCase
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            guard let self, generation == publicGeneration, let tab, !tab.isClosed else { return }
            tab.send(.findResult(Self.approximate(found: result.matchFound)))
        }
    }
}

/// Tells the tab's finder when a new main frame document commits.
@MainActor
final class FindResponder: NavigationResponder {
    func didCommit(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {
        tab.finder.pageChanged()
    }
}
