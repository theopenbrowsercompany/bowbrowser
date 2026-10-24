import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// Web Inspector opens docked beside the page in the tab's own off screen window, never in a window of its own;
/// `hasInspector` follows WebKit, also when the inspector closes itself; and it closes with its tab.
@Suite(.serialized) @MainActor struct InspectorTests {
    init() {
        TestHost.start()
    }

    /// Every web view in `view`'s tree other than `page`: the inspector's own page, once it is docked.
    private func inspectorViews(in view: NSView?, besides page: WKWebView?) -> [WKWebView] {
        guard let view else { return [] }
        var found: [WKWebView] = []
        if let webView = view as? WKWebView, webView !== page { found.append(webView) }
        for subview in view.subviews { found += inspectorViews(in: subview, besides: page) }
        return found
    }

    /// Runs `body` in the inspector front end's own world, where its `InspectorFrontendHost` lives.
    private func inPageWorld(_ webView: WKWebView, _ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    /// The process's visible windows other than the tests' own, for the check that the inspector made none (other
    /// suites open and close test windows meanwhile).
    private func otherVisibleWindows() -> [String] {
        NSApp.windows.filter { $0.isVisible && !($0 is TestWindow) }.map { "\(type(of: $0)) \($0.frame)" }
    }

    private func loadedTab(_ rig: TabRig) async throws -> WebKitTab {
        let tab = rig.tab("/navigation/start.html")
        try await rig.waitFor("finish \(rig.url("/navigation/start.html"))")
        return tab
    }

    @Test func showDocksBesideThePageAndCloseRemovesIt() async throws {
        let rig = try TabRig()
        let tab = try await loadedTab(rig)
        let violations = IsolationMonitor.violations.count
        #expect(!tab.hasInspector)

        tab.showInspector(inspectingAt: nil)
        try await waitUntil("the inspector docked in the tab's window", timeout: 20) {
            tab.hasInspector && inspectorViews(in: rig.window.contentView, besides: tab.webView).count == 1
        }
        // Docked beside the page, in the surface view the page is in.
        #expect(inspectorViews(in: rig.surface, besides: tab.webView).count == 1)
        #expect(otherVisibleWindows().isEmpty, "the inspector opened a window of its own")
        #expect(IsolationMonitor.violations.count == violations, "\(IsolationMonitor.violations)")
        // Showing again keeps the one inspector.
        tab.showInspector(inspectingAt: PagePoint(x: 10, y: 10))
        #expect(tab.hasInspector && inspectorViews(in: rig.window.contentView, besides: tab.webView).count == 1)

        tab.closeInspector()
        try await waitUntil("the inspector closed", timeout: 10) {
            !tab.hasInspector && inspectorViews(in: rig.window.contentView, besides: tab.webView).isEmpty
        }
        #expect(IsolationMonitor.violations.count == violations)
        try await rig.finish()
    }

    /// The inspector's own close button (`InspectorFrontendHost.closeWindow()`, what the button runs) closes it, and
    /// the tab reads that from WebKit.
    @Test func closingFromInsideTheInspectorCounts() async throws {
        let rig = try TabRig()
        let tab = try await loadedTab(rig)
        tab.showInspector(inspectingAt: nil)
        let inspector = try await waitFor("the inspector's page", timeout: 20) {
            tab.hasInspector ? inspectorViews(in: rig.window.contentView, besides: tab.webView).first : nil
        }
        try await waitUntil("the inspector's front end loaded", timeout: 20) {
            try await inPageWorld(
                inspector, "return typeof InspectorFrontendHost === 'object' && document.readyState === 'complete'")
                as? Bool == true
        }
        _ = try? await inPageWorld(inspector, "InspectorFrontendHost.closeWindow(); return true")
        try await waitUntil("the inspector closed itself", timeout: 10) {
            !tab.hasInspector && inspectorViews(in: rig.window.contentView, besides: tab.webView).isEmpty
        }
        try await rig.finish()
    }

    /// Given an attachment view, the inspector docks beside that view instead (in its superview).
    @Test func attachmentViewChoosesWhereItDocks() async throws {
        let rig = try TabRig()
        let tab = try await loadedTab(rig)
        // The surface view is the attachment view: the inspector shares the window's content view with it.
        tab.setInspectorAttachmentView(rig.surface)
        tab.showInspector(inspectingAt: nil)
        try await waitUntil("the inspector docked beside the surface view", timeout: 20) {
            tab.hasInspector
                && rig.window.contentView?.subviews.contains { $0 is WKWebView && $0 !== tab.webView } == true
        }
        #expect(inspectorViews(in: rig.surface, besides: tab.webView).isEmpty)
        tab.closeInspector()
        try await waitUntil("the inspector closed", timeout: 10) {
            !tab.hasInspector && inspectorViews(in: rig.window.contentView, besides: tab.webView).isEmpty
        }
        try await rig.finish()
    }

    /// Closing the tab closes its inspector, and neither keeps the page alive (`finish` checks the release).
    @Test func inspectorClosesWithItsTab() async throws {
        let rig = try TabRig()
        let tab = try await loadedTab(rig)
        tab.showInspector(inspectingAt: nil)
        weak let inspectorPage = try await waitFor("the inspector's page", timeout: 20) {
            tab.hasInspector ? inspectorViews(in: rig.window.contentView, besides: tab.webView).first : nil
        }
        #expect(inspectorPage != nil)
        #expect(await tab.close())
        #expect(!tab.hasInspector)
        tab.showInspector(inspectingAt: nil)
        #expect(!tab.hasInspector)
        try await waitUntil("the inspector left the window", timeout: 10) {
            inspectorViews(in: rig.window.contentView, besides: nil).isEmpty
        }
        try await rig.finish()
        try await waitUntil("the inspector's page is released", timeout: 10) { inspectorPage == nil }
    }
}
