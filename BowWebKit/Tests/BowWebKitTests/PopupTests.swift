import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab delegate that answers every popup with `decision`, records each request and each tab handed over, and gives
/// each new tab its own recording delegate, as the app takes a popup.
@MainActor
final class PopupRecordingDelegate: EngineTabDelegate {
    var decision: PopupDecision
    private(set) var requests: [PopupRequest] = []
    private(set) var opened: [(tab: WebKitTab, request: PopupRequest)] = []
    /// Each opened tab's delegate, by tab ID.
    private(set) var popupDelegates: [TabID: RecordingTabDelegate] = [:]
    /// What the opener was told about the new tab as it arrived: whether it was closed and had a page.
    private(set) var arrivedOpen: [Bool] = []

    init(_ decision: PopupDecision) {
        self.decision = decision
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {}

    func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision {
        requests.append(request)
        return decision
    }

    func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest) {
        let popup = newTab as! WebKitTab
        arrivedOpen.append(!popup.isClosed && popup.webView != nil)
        let delegate = RecordingTabDelegate()
        popupDelegates[popup.tabID] = delegate
        popup.delegate = delegate
        // Test host only: a page no window shows counts as occluded, and WebKit throttles it.
        if let webView = popup.webView { WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false) }
        opened.append((popup, request))
    }

    /// Waits for the `count`th tab handed over and returns it with its request.
    func waitForPopup(_ count: Int) async throws -> (tab: WebKitTab, request: PopupRequest) {
        try await waitFor("popup \(count); asked \(requests.count), opened \(opened.count)") {
            opened.count >= count ? opened[count - 1] : nil
        }
    }

    /// Waits for the `count`th request and returns it.
    func waitForRequest(_ count: Int) async throws -> PopupRequest {
        try await waitFor("popup request \(count); asked \(requests.count)") {
            requests.count >= count ? requests[count - 1] : nil
        }
    }
}

/// Pages a page opens (`window.open`, a link with a target) reach `decidePopup` with what the page asked; every
/// decision but `.block` hands a new tab of the opener's profile to `didOpenPopup`, still connected to its opener; a
/// page a script opened that calls `window.close()` closes its tab as the page's own close; and quitting closes popup
/// tabs too.
@Suite(.serialized) @MainActor struct PopupTests {
    init() {
        TestHost.start()
    }

    /// The opener's title, which the child sets through `window.opener`.
    private func openerTitle(_ tab: WebKitTab) async throws -> String {
        try await PageDriver(tab.webView!).string("return document.title")
    }

    /// What the opener's last `window.open` returned: "window", "null", or "none" before any.
    private func openResult(_ tab: WebKitTab) async throws -> String {
        try await PageDriver(tab.webView!).string(
            "return document.body.dataset.opened || 'none'")
    }

    /// Clicks `selector` in the tab's page as a person would, so the page opens with a user gesture.
    private func click(_ selector: String, in tab: WebKitTab) async throws {
        try await PageDriver(tab.webView!).click(selector)
    }

    /// Closes the popups and checks each web view is released.
    private func finish(_ popups: [WebKitTab]) async throws {
        let boxes = popups.compactMap { $0.webView.map(WeakBox.init) }
        for popup in popups { _ = await popup.close() }
        try await waitUntil("every popup web view is released", timeout: 5) { boxes.allSatisfy { $0.object == nil } }
    }

    @Test func everyDecisionButBlockHandsOverATabThatKeepsItsOpener() async throws {
        let rig = try TabRig()
        let page = rig.url("/popups/opener.html")
        let child = rig.url("/popups/child.html")
        let opener = rig.tab("/popups/opener.html")
        let delegate = PopupRecordingDelegate(.foregroundTab)
        opener.delegate = delegate
        try await PageDriver(opener.webView!).waitForLoad(of: page)

        let decisions: [PopupDecision] = [.foregroundTab, .backgroundTab, .popupPanel, .peek, .window]
        for (index, decision) in decisions.enumerated() {
            delegate.decision = decision
            try await PageDriver(opener.webView!).eval(
                "document.title = 'Popup opener'; document.body.dataset.opened = ''")
            try await click("#tab", in: opener)
            let (popup, request) = try await delegate.waitForPopup(index + 1)
            #expect(delegate.requests.count == index + 1, "\(decision): asked once")
            #expect(
                request
                    == PopupRequest(targetURL: child, disposition: .foregroundTab, isUserGesture: true),
                "\(decision): \(request)")
            #expect(delegate.arrivedOpen[index], "\(decision): the tab arrived without its page")
            #expect(popup !== opener && popup.profile === rig.profile && popup.profileID == opener.profileID)
            #expect(rig.profile.openTabs.contains { $0 === popup }, "\(decision): the popup is not registered")
            // The child loads in the new tab and reaches its opener through window.opener.
            try await waitUntil(
                "\(decision): the child loaded with its opener; title \(popup.state.title), url \(popup.state.url?.absoluteString ?? "nil")"
            ) {
                popup.state.url == child && popup.state.title == "Popup child with opener"
            }
            let title = try await waitFor("\(decision): the child set the opener's title") {
                let title = try await openerTitle(opener)
                return title == "Set by the child" ? title : nil
            }
            #expect(title == "Set by the child")
            #expect(try await openResult(opener) == "window", "\(decision): window.open returned no window")
        }
        try await finish(delegate.opened.map(\.tab))
        try await rig.finish()
    }

    @Test func blockOpensNothingAndWindowOpenReturnsNull() async throws {
        let rig = try TabRig()
        let page = rig.url("/popups/opener.html")
        let opener = rig.tab("/popups/opener.html")
        let delegate = PopupRecordingDelegate(.block)
        opener.delegate = delegate
        try await PageDriver(opener.webView!).waitForLoad(of: page)
        let before = rig.profile.openTabs.count

        try await click("#tab", in: opener)
        let request = try await delegate.waitForRequest(1)
        #expect(request.targetURL == rig.url("/popups/child.html") && request.isUserGesture)
        let result = try await waitFor("window.open returned") {
            let result = try await openResult(opener)
            return result == "none" ? nil : result
        }
        #expect(result == "null", "window.open did not return null")
        #expect(delegate.opened.isEmpty)
        #expect(rig.profile.openTabs.count == before)
        try await rig.finish()
    }

    /// A sized `window.open` asks for a popup window, and a link with a target asks for a foreground tab.
    @Test func theRequestCarriesTheFeaturesAndALinkAsksLikeWindowOpen() async throws {
        let rig = try TabRig()
        let page = rig.url("/popups/opener.html")
        let child = rig.url("/popups/child.html")
        let opener = rig.tab("/popups/opener.html")
        let delegate = PopupRecordingDelegate(.popupPanel)
        opener.delegate = delegate
        try await PageDriver(opener.webView!).waitForLoad(of: page)

        try await click("#sized", in: opener)
        let sized = try await delegate.waitForPopup(1).request
        #expect(sized.targetURL == child && sized.isUserGesture)
        #expect(sized.disposition == .popup)
        #expect(sized.requestedSize == PopupSize(width: 480, height: 560))
        #expect(sized.windowFeatures.width == 480 && sized.windowFeatures.height == 560)
        #expect(sized.windowFeatures.isPopup)
        #expect(PopupPolicy.opensPanel(sized), "Bow's rules would not show the sign in popup in a panel")

        delegate.decision = .foregroundTab
        try await PageDriver(opener.webView!).eval("document.title = 'Popup opener'")
        try await click("#link", in: opener)
        let (linked, link) = try await delegate.waitForPopup(2)
        #expect(link == PopupRequest(targetURL: child, disposition: .foregroundTab, isUserGesture: true))
        try await waitUntil("the linked child loaded with its opener; title \(linked.state.title)") {
            linked.state.title == "Popup child with opener"
        }
        try await finish(delegate.opened.map(\.tab))
        try await rig.finish()
    }

    /// With no user gesture WebKit's popup blocker refuses `window.open` before the tab is asked: the page gets null
    /// and `decidePopup` is never called (the answer Bow's rules give such a request).
    @Test func windowOpenWithoutAGestureReturnsNullUnasked() async throws {
        let rig = try TabRig()
        let page = rig.url("/popups/opener.html?auto")
        let opener = rig.tab("/popups/opener.html?auto")
        let delegate = PopupRecordingDelegate(.foregroundTab)
        opener.delegate = delegate
        try await PageDriver(opener.webView!).waitForLoad(of: page)
        let result = try await waitFor("the page's automatic window.open returned") {
            let value = try await openResult(opener)
            return value == "none" ? nil : value
        }
        #expect(result == "null", "a window.open without a gesture opened a window")
        #expect(delegate.requests.isEmpty, "decidePopup was asked about a request without a gesture")
        #expect(delegate.opened.isEmpty)
        try await rig.finish()
    }

    /// A tab whose delegate does not take popups closes the new tab (the contract's default), and a tab with no
    /// delegate opens nothing.
    @Test func aPopupNobodyTakesCloses() async throws {
        let rig = try TabRig()
        let page = rig.url("/popups/opener.html")
        let opener = rig.tab("/popups/opener.html")
        // RecordingTabDelegate keeps the defaults: decidePopup says .window and didOpenPopup closes the tab.
        try await PageDriver(opener.webView!).waitForLoad(of: page)
        try await click("#tab", in: opener)
        try await waitUntil("window.open returned; \(try await openResult(opener))") {
            try await openResult(opener) == "window"
        }
        try await waitUntil("the untaken popup closed; open \(rig.profile.openTabs.count)") {
            rig.profile.openTabs.count == 1 && rig.profile.openTabs.first === opener
        }

        opener.delegate = nil
        try await PageDriver(opener.webView!).eval("document.body.dataset.opened = ''")
        try await click("#tab", in: opener)
        try await waitUntil("window.open returned with no delegate; \(try await openResult(opener))") {
            try await openResult(opener) != "none"
        }
        #expect(try await openResult(opener) == "null")
        #expect(rig.profile.openTabs.count == 1)
        try await rig.finish()
    }

    /// A page a script opened that calls `window.close()` closes its tab: `TabEvent.closed` arrives, the tab is
    /// closed with `.page`, and its web view goes. The opener stays.
    @Test func windowCloseInAScriptOpenedTabClosesIt() async throws {
        let rig = try TabRig()
        let page = rig.url("/popups/opener.html")
        let opener = rig.tab("/popups/opener.html")
        let delegate = PopupRecordingDelegate(.foregroundTab)
        opener.delegate = delegate
        try await PageDriver(opener.webView!).waitForLoad(of: page)

        try await click("#closer", in: opener)
        let (popup, request) = try await delegate.waitForPopup(1)
        #expect(request.targetURL == rig.url("/popups/closer.html"))
        weak let released = popup.webView
        let popupDelegate = try #require(delegate.popupDelegates[popup.tabID])
        _ = try await popupDelegate.wait(for: "the closer's closed event; saw \(popupDelegate.events)") {
            $0 == .closed
        }
        #expect(popup.isClosed && popup.closeReason == .page && popup.webView == nil)
        #expect(!opener.isClosed)
        try await waitUntil("the closed popup's web view is released", timeout: 5) { released == nil }

        // A tab the person opened, with history to go back to, ignores window.close(), as in every browser: WebKit
        // refuses the close (window.closed stays false) and the tab stays open.
        let a = rig.url("/navigation/a.html")
        opener.load(a)
        try await PageDriver(opener.webView!).waitForLoad(of: a)
        #expect(try await PageDriver(opener.webView!).bool("window.close(); return window.closed") == false)
        #expect(try await PageDriver(opener.webView!).string("return document.title") == "A")
        #expect(!opener.isClosed && opener.closeReason == nil)
        try await rig.finish()
    }

    /// Quitting closes a popup tab with `.quit`, as every tab; a popup asked for while the profile quits is born
    /// closed with `.quit`, never handed over, and the page gets null.
    @Test func quitClosesPopupTabsAndRefusesNewOnes() async throws {
        try await withEngine(TestStores()) { rig in
            let main = try #require(rig.engine.profile(id: .default) as? WebKitProfile)
            let page = rig.server.url("/popups/opener.html")
            let opener = rig.tab(in: main, "/popups/opener.html")
            rig.window.contentView?.addSubview(opener.webView!)
            opener.webView!.frame = rig.window.contentView!.bounds
            let delegate = PopupRecordingDelegate(.backgroundTab)
            opener.delegate = delegate
            try await PageDriver(opener.webView!).waitForLoad(of: page)
            try await click("#tab", in: opener)
            let popup = try await delegate.waitForPopup(1).tab
            #expect(main.openTabs.contains { $0 === popup })

            // A popup asked for after the quit began.
            main.beginQuit()
            try await PageDriver(opener.webView!).eval("document.body.dataset.opened = ''")
            try await click("#tab", in: opener)
            _ = try await delegate.waitForRequest(2)
            try await waitUntil("window.open returned during the quit; \(try await openResult(opener))") {
                try await openResult(opener) != "none"
            }
            #expect(try await openResult(opener) == "null", "a popup opened during the quit")
            #expect(delegate.opened.count == 1, "a refused popup was handed over")

            let box = WeakBox(popup.webView!)
            await rig.engine.quit()
            #expect(popup.isClosed && popup.closeReason == .quit && popup.webView == nil)
            #expect(opener.isClosed && opener.closeReason == .quit)
            try await waitUntil("the popup's web view is released", timeout: 5) { box.object == nil }
        }
    }
}

/// The mapping of WebKit's window features and click to Bow's popup request.
@Suite struct PopupValueTests {
    @Test func featuresAskForAPopupUnlessNoneArePassedOrEveryBarIsOn() {
        func popup(_ geometry: Bool, _ bars: Bool?...) -> Bool {
            PopupWindowFeatures.isPopup(
                hasGeometry: geometry, menuBar: bars[0], statusBar: bars[1], toolbars: bars[2], resizable: bars[3])
        }
        #expect(!popup(false, nil, nil, nil, nil), "no features is a tab")
        #expect(popup(true, nil, nil, nil, nil), "a size alone is a popup")
        #expect(!popup(true, true, true, true, true), "every bar and resizing on is a tab")
        #expect(!popup(false, true, true, true, true))
        #expect(popup(false, false, true, true, true))
        #expect(popup(false, nil, nil, true, nil), "a bar left out counts as off")
        #expect(popup(false, true, true, true, false))
    }

    @Test func aModifiedClickDecidesTheDispositionBeforeTheFeatures() {
        let cases: [(PopupClickModifiers, Bool, PopupDisposition)] = [
            (.none, false, .foregroundTab),
            (.none, true, .popup),
            (PopupClickModifiers(command: true), true, .backgroundTab),
            (PopupClickModifiers(command: true, shift: true), false, .foregroundTab),
            (PopupClickModifiers(shift: true), false, .window),
        ]
        for (modifiers, isPopup, expected) in cases {
            #expect(PopupDisposition(isPopup: isPopup, modifiers: modifiers) == expected, "\(modifiers) \(isPopup)")
        }
    }

    @Test func clickModifiersComeFromTheFlagsAndTheMiddleButtonOnlyWithAGesture() {
        let url = URL(string: "https://example.com/")!
        let features = PopupWindowFeatures(width: 400, height: 300, isPopup: true)
        let middle = PopupRequest(
            targetURL: url, features: features, isUserGesture: true, modifierFlags: [], buttonNumber: 2)
        #expect(middle.clickModifiers == PopupClickModifiers(command: true))
        #expect(middle.disposition == .backgroundTab)
        #expect(middle.requestedSize == PopupSize(width: 400, height: 300))
        let commandShift = PopupRequest(
            targetURL: url, features: PopupWindowFeatures(), isUserGesture: true,
            modifierFlags: [.command, .shift], buttonNumber: 0)
        #expect(commandShift.clickModifiers == PopupClickModifiers(command: true, shift: true))
        #expect(commandShift.requestedSize == nil)
        let noGesture = PopupRequest(
            targetURL: url, features: features, isUserGesture: false, modifierFlags: [.command], buttonNumber: 0)
        #expect(noGesture.clickModifiers == .none && noGesture.disposition == .popup && !noGesture.isUserGesture)
    }
}
