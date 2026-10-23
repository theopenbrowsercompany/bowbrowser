import BowCore
import Foundation
import Testing

@Suite struct PeekPolicyTests {
    let page = URL(string: "https://news.example.com/today")!

    func click(_ address: String, transition: NavigationTransition = .link, gesture: Bool = true) -> EngineNavigation {
        EngineNavigation(url: URL(string: address)!, transition: transition, isUserGesture: gesture)
    }

    func outcome(
        _ navigation: EngineNavigation, from zone: PopupOpenerZone, current: URL? = nil,
        context: PeekContext = .arcDefault
    ) -> PeekNavigationOutcome {
        PeekPolicy.navigationOutcome(navigation, currentURL: current ?? page, openerZone: zone, context: context)
    }

    func opens(
        _ navigation: EngineNavigation, from zone: PopupOpenerZone, current: URL? = nil,
        context: PeekContext = .arcDefault
    ) -> Bool {
        outcome(navigation, from: zone, current: current, context: context) == .peek
    }

    @Test func arcDefaultsAreOn() {
        #expect(PeekSettings.arcDefault.shiftClickOpensPeek)
        #expect(PeekSettings.arcDefault.offSiteLinksOpenPeek)
        #expect(!PeekContext.arcDefault.isOpen)
    }

    @Test func sameSiteComparesHostsWithoutCaseOrWww() {
        let site = { (a: String, b: String) in PeekPolicy.isSameSite(URL(string: a)!, URL(string: b)!) }
        #expect(site("https://example.com/a", "https://EXAMPLE.com/b"))
        #expect(site("https://www.example.com/", "https://example.com/x"))
        #expect(site("http://example.com/", "https://example.com/"))
        #expect(!site("https://mail.example.com/", "https://docs.example.com/"))
        #expect(!site("https://example.com/", "https://example.org/"))
        #expect(!site("about:blank", "about:blank"))
    }

    @Test func offSiteLinkFromPinnedOrFavoriteOpensPeek() {
        #expect(opens(click("https://other.test/story"), from: .pinned))
        #expect(opens(click("https://other.test/story"), from: .favorite))
    }

    @Test func offSiteLinkFromTodayNavigates() {
        #expect(outcome(click("https://other.test/story"), from: .today) == .navigate)
    }

    @Test func sameSiteLinkFromPinnedNavigates() {
        #expect(outcome(click("https://news.example.com/sports"), from: .pinned) == .navigate)
        #expect(outcome(click("https://www.news.example.com/sports"), from: .favorite) == .navigate)
    }

    @Test func settingOffOpensANewTabInstead() {
        let off = PeekContext(settings: PeekSettings(offSiteLinksOpenPeek: false))
        #expect(outcome(click("https://other.test/"), from: .pinned, context: off) == .newTab)
        #expect(outcome(click("https://other.test/"), from: .favorite, context: off) == .newTab)
        #expect(outcome(click("https://news.example.com/x"), from: .pinned, context: off) == .navigate)
        #expect(outcome(click("https://other.test/"), from: .today, context: off) == .navigate)
    }

    @Test func onlyClickedLinksOpenPeek() {
        for transition in [NavigationTransition.typed, .formSubmit, .reload, .backForward, .other] {
            #expect(outcome(click("https://other.test/", transition: transition), from: .pinned) == .navigate)
        }
        #expect(outcome(click("https://other.test/", gesture: false), from: .pinned) == .navigate)
    }

    @Test func aRedirectNeverOpensPeek() {
        // A same-site link the tab followed, redirected by the server to another site, stays in the tab.
        let redirect = EngineNavigation(
            url: URL(string: "https://accounts.other.test/signin")!, transition: .link, isUserGesture: true,
            isRedirect: true)
        #expect(outcome(redirect, from: .pinned) == .navigate)
        #expect(outcome(redirect, from: .favorite) == .navigate)
        #expect(outcome(redirect, from: .today) == .navigate)
        let off = PeekContext(settings: PeekSettings(offSiteLinksOpenPeek: false))
        #expect(outcome(redirect, from: .pinned, context: off) == .navigate)
        // Even a redirect to the address already handed over is no second ask about that link.
        #expect(outcome(redirect, from: .pinned, context: PeekContext(handledURL: redirect.url)) == .navigate)
        // The navigation's first ask still opens a Peek.
        var first = redirect
        first.isRedirect = false
        #expect(outcome(first, from: .pinned) == .peek)
    }

    @Test func navigationsAreFirstAsksByDefault() {
        #expect(!EngineNavigation(url: page).isRedirect)
    }

    @Test func nonWebAddressesNavigate() {
        #expect(outcome(click("mailto:someone@example.com"), from: .pinned) == .navigate)
        #expect(outcome(click("https://other.test/"), from: .pinned, current: URL(string: "about:blank")!) == .navigate)
        #expect(
            PeekPolicy.navigationOutcome(
                click("https://other.test/"), currentURL: nil, openerZone: .pinned, context: .arcDefault) == .navigate)
    }

    @Test func aSecondAskAboutTheSameLinkOpensNothing() {
        let link = click("https://other.test/story")
        let handled = PeekContext(isOpen: true, handledURL: link.url)
        #expect(outcome(link, from: .pinned, context: handled) == .alreadyHandled)
        let pendingTab = PeekContext(settings: PeekSettings(offSiteLinksOpenPeek: false), handledURL: link.url)
        #expect(outcome(link, from: .favorite, context: pendingTab) == .alreadyHandled)
        // Another link is not the one handled, and a same-site link still navigates.
        #expect(outcome(click("https://other.test/else"), from: .pinned, context: handled) == .newTab)
        #expect(
            outcome(click("https://news.example.com/x"), from: .pinned, context: PeekContext(handledURL: page))
                == .navigate)
    }

    @Test func noSecondPeekWhileOneIsOpen() {
        #expect(outcome(click("https://other.test/"), from: .pinned, context: PeekContext(isOpen: true)) == .newTab)
        #expect(PeekPolicy.shiftClickDecision(context: PeekContext(isOpen: true)) == .block)
        #expect(PeekPolicy.shiftClickDecision(context: .arcDefault) == .peek)
        let off = PeekContext(settings: PeekSettings(shiftClickOpensPeek: false), isOpen: true)
        #expect(PeekPolicy.shiftClickDecision(context: off) == .foregroundTab)
    }

    @Test func pagesThePeekOpensBecomeTabsOrPanels() {
        let target = URL(string: "https://other.test/")!
        let request = { (modifiers: PopupClickModifiers, gesture: Bool) in
            PopupRequest(
                targetURL: target, disposition: .foregroundTab, isUserGesture: gesture, clickModifiers: modifiers)
        }
        #expect(PeekPolicy.decisionInPeek(for: request(.none, true)) == .foregroundTab)
        #expect(PeekPolicy.decisionInPeek(for: request(PopupClickModifiers(shift: true), true)) == .foregroundTab)
        #expect(PeekPolicy.decisionInPeek(for: request(PopupClickModifiers(command: true), true)) == .backgroundTab)
        #expect(PeekPolicy.decisionInPeek(for: request(.none, false)) == .block)
        let signIn = PopupRequest(
            targetURL: target, disposition: .popup, isUserGesture: true,
            windowFeatures: PopupWindowFeatures(width: 480, height: 560, isPopup: true))
        #expect(PeekPolicy.decisionInPeek(for: signIn) == .popupPanel)
    }

    @Test func promotedPeekGoesWhereItsSourcesNewPagesGo() {
        #expect(PeekPolicy.promotedPlacement(openerZone: .today) == .afterOpener)
        #expect(PeekPolicy.promotedPlacement(openerZone: .pinned) == .topOfToday)
        #expect(PeekPolicy.promotedPlacement(openerZone: .favorite) == .topOfToday)
    }

    @Test func onlyADismissedPeekMayStayAtItsLeavePrompt() {
        #expect(PeekPolicy.pageMayStay(.dismissed))
        #expect(!PeekPolicy.pageMayStay(.sourceGone))
        #expect(!PeekPolicy.pageMayStay(.sourceHidden))
        #expect(!PeekPolicy.pageMayStay(.windowClosing))
    }

    @Test func cardIsCenteredWithMarginsAndAToolbarRow() {
        let card = PeekLayout.cardFrame(width: 1000, height: 800)
        #expect(card.width == 920)
        #expect(card.height == 800 - 80 - 32)
        #expect(card.x == 40)
        #expect(card.y == 40)
    }

    @Test func cardStopsGrowingOnAWideWindow() {
        let card = PeekLayout.cardFrame(width: 2000, height: 800)
        #expect(card.width == PeekLayout.maxCardWidth)
        #expect(card.x == 400)
    }

    @Test func cardKeepsAMinimumOnATinyWindow() {
        let card = PeekLayout.cardFrame(width: 100, height: 100)
        #expect(card.width == 240)
        #expect(card.height == 160)
        #expect(card.y == 0)
    }
}
