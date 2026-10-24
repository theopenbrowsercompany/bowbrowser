import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A modified click on a plain link (no target), which WebKit would load in the same tab, asks the tab delegate's
/// `decidePopup` with the click's disposition and modifiers and a user gesture, as Chromium's `OnOpenURLFromTab` asks
/// on CEF: a tab decision opens the link in a new tab of the profile with the click's referrer and no opener, and
/// leaves the clicked tab on its page; a block opens nothing; a plain click or a link into a frame asks nothing.
@Suite(.serialized) @MainActor struct LinkDispositionTests {
    init() {
        TestHost.start()
    }

    /// The tab on the links page, with a delegate that decides by Bow's rules for a Today tab, as the app does.
    private func linksTab(_ rig: TabRig) async throws -> (WebKitTab, PopupRecordingDelegate) {
        let opener = rig.tab("/popups/links.html")
        let delegate = PopupRecordingDelegate(.block)
        delegate.decidesByPolicy = true
        try await PageDriver(opener.webView!).waitForLoad(of: rig.url("/popups/links.html"))
        // After the load, so the rig's recording delegate saw the page's own navigation.
        opener.delegate = delegate
        return (opener, delegate)
    }

    /// The page's DOM value `name` (`referrer`, `opener`) in `tab`, or nil before the page set it.
    private func pageValue(_ name: String, in tab: WebKitTab) async throws -> String? {
        guard let webView = tab.webView else { return nil }
        let value = try await PageDriver(webView).string(
            "return document.documentElement.dataset[name] || ''", ["name": name])
        return value.isEmpty ? nil : value
    }

    /// Clicks `selector` in the tab's page with `modifiers` held. No driver outlives the call, so the page can go.
    private func click(_ selector: String, modifiers: NSEvent.ModifierFlags, in tab: WebKitTab) async throws {
        let driver = PageDriver(tab.webView!)
        try await driver.click(try await driver.centre(of: selector), modifiers: modifiers)
    }

    /// Checks the clicked tab is still on the links page and never started loading `linked`.
    private func expectStayed(_ opener: WebKitTab, _ rig: TabRig, _ linked: URL, _ what: String) async throws {
        let page = rig.url("/popups/links.html")
        #expect(
            opener.webView?.url == page, "\(what): the clicked tab moved to \(String(describing: opener.webView?.url))")
        #expect(try await PageDriver(opener.webView!).string("return document.title") == "Plain links", "\(what)")
        #expect(
            !rig.delegate.navigation.contains("start \(linked.absoluteString)"),
            "\(what): the clicked tab started the link; saw \(rig.delegate.navigation)")
    }

    @Test func aModifiedClickOnAPlainLinkAsksAndOpensANewTab() async throws {
        let rig = try TabRig()
        let page = rig.url("/popups/links.html")
        let linked = rig.url("/popups/linked.html")
        let (opener, delegate) = try await linksTab(rig)

        let clicks: [(String, NSEvent.ModifierFlags, Bool, PopupDisposition, PopupClickModifiers, PopupDecision)] = [
            ("Command", [.command], false, .backgroundTab, PopupClickModifiers(command: true), .backgroundTab),
            (
                "Command Shift", [.command, .shift], false, .foregroundTab,
                PopupClickModifiers(command: true, shift: true), .foregroundTab
            ),
            ("middle", [], true, .backgroundTab, PopupClickModifiers(command: true), .backgroundTab),
            // Shift asks for a window, as on CEF, which Bow's rules answer with a Peek, a tab of its own.
            ("Shift", [.shift], false, .window, PopupClickModifiers(shift: true), .peek),
        ]
        for (index, (name, flags, middle, disposition, modifiers, decision)) in clicks.enumerated() {
            let driver = PageDriver(opener.webView!)
            let point = try await driver.centre(of: "#plain")
            if middle {
                try await driver.middleClick(point)
            } else {
                try await driver.click(point, modifiers: flags)
            }
            let (tab, request) = try await delegate.waitForPopup(index + 1)
            #expect(delegate.requests.count == index + 1, "\(name): asked \(delegate.requests.count) times")
            #expect(
                request
                    == PopupRequest(
                        targetURL: linked, disposition: disposition, isUserGesture: true, clickModifiers: modifiers),
                "\(name): \(request)")
            #expect(
                PopupPolicy.outcome(for: request, openerZone: .today).decision == decision,
                "\(name): Bow's rules gave another decision")
            #expect(tab !== opener && tab.profile === rig.profile && !tab.isPopupWindow, "\(name)")
            #expect(rig.profile.openTabs.contains { $0 === tab }, "\(name): the new tab is not registered")
            #expect(delegate.arrivedOpen[index], "\(name): the new tab arrived without its page")
            // The new tab loads the link, with the click's referrer and no opener, and its first load asked the
            // new tab's own delegate, which the app had set before it.
            try await waitUntil(
                "\(name): the new tab loaded the link; url \(tab.state.url?.absoluteString ?? "nil"), title \(tab.state.title)"
            ) {
                guard tab.state.url == linked, tab.state.title == "Linked page" else { return false }
                return try await pageValue("referrer", in: tab) != nil
            }
            #expect(try await pageValue("referrer", in: tab) == page.absoluteString, "\(name): the referrer")
            #expect(try await pageValue("opener", in: tab) == "none", "\(name): a modified click kept an opener")
            let policy = delegate.popupDelegates[tab.tabID]?.policyRequests.map(\.url) ?? []
            #expect(policy.first == linked, "\(name): the new tab's first load was not asked: \(policy)")
            try await expectStayed(opener, rig, linked, name)
        }

        // A link whose referrer policy sends none opens with none.
        try await click("#noreferrer", modifiers: [.command], in: opener)
        let quiet = try await delegate.waitForPopup(clicks.count + 1).tab
        try await waitUntil("the no-referrer link loaded; url \(quiet.state.url?.absoluteString ?? "nil")") {
            (try await pageValue("referrer", in: quiet)) != nil
        }
        #expect(try await pageValue("referrer", in: quiet) == "none", "a no-referrer link sent a referrer")

        let tabs = delegate.opened.map(\.tab)
        let boxes = tabs.compactMap { $0.webView.map(WeakBox.init) }
        for tab in tabs { _ = await tab.close() }
        try await waitUntil("every new tab's web view is released", timeout: 5) {
            boxes.allSatisfy { $0.object == nil }
        }
        try await rig.finish()
    }

    @Test func aPlainClickStillLoadsInTheTabAndAsksNothing() async throws {
        let rig = try TabRig()
        let linked = rig.url("/popups/linked.html")
        let framed = rig.url("/popups/linked.html?framed")
        let (opener, delegate) = try await linksTab(rig)

        // A Command-click on a link into a frame loads in the frame, as before.
        try await click("#framed", modifiers: [.command], in: opener)
        try await waitUntil("the frame loaded the link; asked \(delegate.requests.count)") {
            try await PageDriver(opener.webView!).string(
                "return document.querySelector('iframe').contentWindow.location.href") == framed.absoluteString
        }
        #expect(delegate.requests.isEmpty, "a link into a frame asked: \(delegate.requests)")
        try await expectStayed(opener, rig, linked, "frame")

        try await PageDriver(opener.webView!).click("#plain")
        try await PageDriver(opener.webView!).waitForLoad(of: linked)
        #expect(opener.state.url == linked)
        #expect(delegate.requests.isEmpty && delegate.opened.isEmpty, "a plain click asked: \(delegate.requests)")
        #expect(rig.profile.openTabs.count == 1)
        try await rig.finish()
    }

    @Test func aBlockedModifiedClickOpensNothingAndStays() async throws {
        let rig = try TabRig()
        let linked = rig.url("/popups/linked.html")
        let (opener, delegate) = try await linksTab(rig)
        delegate.decidesByPolicy = false

        try await click("#plain", modifiers: [.command], in: opener)
        let request = try await delegate.waitForRequest(1)
        #expect(request.targetURL == linked && request.disposition == .backgroundTab && request.isUserGesture)
        #expect(delegate.opened.isEmpty, "a blocked click opened a tab")
        #expect(rig.profile.openTabs.count == 1)
        #expect(opener.webView?.isLoading == false, "the clicked tab is loading")
        try await expectStayed(opener, rig, linked, "block")

        // A `.window` decision lets the link load in the tab, as CEF's engine default does.
        delegate.decision = .window
        try await click("#plain", modifiers: [.command], in: opener)
        _ = try await delegate.waitForRequest(2)
        try await PageDriver(opener.webView!).waitForLoad(of: linked)
        #expect(delegate.opened.isEmpty && rig.profile.openTabs.count == 1, "a window decision opened a tab")
        try await rig.finish()
    }
}

@MainActor private var modifiedClickEventNumber = 20_000

extension PageDriver {
    /// A left click at `point` (page coordinates) with `modifiers` held, as a real mouse move, down and up; returns
    /// once WebKit has handled them.
    func click(_ point: CGPoint, modifiers: NSEvent.ModifierFlags) async throws {
        guard let window = webView.window else { throw TestError("the web view is in no window") }
        let at = windowPoint(point)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            modifiedClickEventNumber += 1
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: modifiedClickEventNumber, clickCount: type == .mouseMoved ? 0 : 1,
                    pressure: type == .leftMouseDown ? 1 : 0)
            else { throw TestError("could not make a \(type) event") }
            window.sendEvent(event)
        }
        _ = await WebKitSPI.afterPendingMouseEvents(webView)
    }
}
