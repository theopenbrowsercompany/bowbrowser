import BowCore
import Foundation
import Testing

@Suite struct PopupPolicyTests {
    let url = URL(string: "https://example.com/")!

    func request(
        gesture: Bool = true, disposition: PopupDisposition = .foregroundTab, features: PopupWindowFeatures = .init(),
        modifiers: PopupClickModifiers = .none
    ) -> PopupRequest {
        PopupRequest(
            targetURL: url, disposition: disposition, isUserGesture: gesture, windowFeatures: features,
            clickModifiers: modifiers)
    }

    @Test func noGestureIsBlocked() {
        let outcome = PopupPolicy.outcome(for: request(gesture: false), openerZone: .today)
        #expect(outcome == PopupOutcome(decision: .block))
    }

    @Test func sizedPopupFromAClickOpensAPanel() {
        let sized = request(disposition: .popup, features: .init(width: 500, height: 600, isPopup: true))
        #expect(PopupPolicy.outcome(for: sized, openerZone: .today) == PopupOutcome(decision: .popupPanel))
        let widthOnly = request(features: .init(width: 500))
        #expect(PopupPolicy.outcome(for: widthOnly, openerZone: .pinned).decision == .popupPanel)
        #expect(PopupPolicy.opensPanel(sized))
    }

    @Test func targetBlankOpensInTheForegroundAfterTheOpener() {
        let outcome = PopupPolicy.outcome(for: request(), openerZone: .today)
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .afterOpener))
    }

    @Test func commandClickOpensInTheBackgroundAfterTheOpener() {
        let outcome = PopupPolicy.outcome(
            for: request(disposition: .backgroundTab, modifiers: .init(command: true)), openerZone: .today)
        #expect(outcome == PopupOutcome(decision: .backgroundTab, placement: .afterOpener))
    }

    @Test func commandShiftClickOpensInTheForegroundAfterTheOpener() {
        let outcome = PopupPolicy.outcome(
            for: request(modifiers: .init(command: true, shift: true)), openerZone: .today)
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .afterOpener))
    }

    @Test func shiftClickOpensAPeekUnderArcDefaults() {
        let outcome = PopupPolicy.outcome(
            for: request(disposition: .window, modifiers: .init(shift: true)), openerZone: .today)
        #expect(outcome == PopupOutcome(decision: .peek))
        let fromPinned = PopupPolicy.outcome(for: request(modifiers: .init(shift: true)), openerZone: .pinned)
        #expect(fromPinned == PopupOutcome(decision: .peek))
    }

    @Test func shiftClickWithPeekOffOpensInTheForeground() {
        let off = PeekContext(settings: PeekSettings(shiftClickOpensPeek: false))
        let outcome = PopupPolicy.outcome(
            for: request(disposition: .window, modifiers: .init(shift: true)), openerZone: .today, peek: off)
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .afterOpener))
    }

    @Test func shiftClickWhileAPeekIsOpenOpensNothing() {
        let open = PeekContext(isOpen: true)
        let outcome = PopupPolicy.outcome(for: request(modifiers: .init(shift: true)), openerZone: .today, peek: open)
        #expect(outcome == PopupOutcome(decision: .block))
        // Other clicks are not Peek's.
        #expect(PopupPolicy.outcome(for: request(), openerZone: .today, peek: open).decision == .foregroundTab)
    }

    @Test func fromPinnedGoesToTopOfToday() {
        let outcome = PopupPolicy.outcome(for: request(), openerZone: .pinned)
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .topOfToday))
    }

    @Test func fromFavoriteGoesToTopOfToday() {
        let outcome = PopupPolicy.outcome(
            for: request(modifiers: .init(command: true, shift: true)), openerZone: .favorite)
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .topOfToday))
    }

    @Test func otherSizeSignalsOpenAPanelAndNoGestureStillWins() {
        let heightOnly = request(features: .init(height: 300))
        let popupFlag = request(features: .init(isPopup: true))
        let sizeAsked = PopupRequest(
            targetURL: url, disposition: .foregroundTab, isUserGesture: true,
            requestedSize: PopupSize(width: 400, height: 300))
        for sized in [heightOnly, popupFlag, sizeAsked] {
            #expect(PopupPolicy.outcome(for: sized, openerZone: .today).decision == .popupPanel)
        }
        let noGestureSized = request(gesture: false, features: .init(width: 500))
        #expect(PopupPolicy.outcome(for: noGestureSized, openerZone: .today).decision == .block)
        #expect(!PopupPolicy.opensPanel(noGestureSized))
    }

    @Test func fromTodayGoesAfterTheOpener() {
        #expect(PopupPolicy.outcome(for: request(), openerZone: .today).placement == .afterOpener)
    }

    func request(to address: String, modifiers: PopupClickModifiers = .none, gesture: Bool = true) -> PopupRequest {
        PopupRequest(
            targetURL: URL(string: address), disposition: .foregroundTab, isUserGesture: gesture,
            clickModifiers: modifiers)
    }

    @Test func identityProviderPagesFromAPlainClickOpenAPanel() {
        for address in [
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=1",
            "https://ACCOUNTS.Google.com/signin",
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://appleid.apple.com/auth/authorize",
            "https://github.com/login/oauth/authorize?client_id=1",
            "https://github.com/login/oauth",
        ] {
            let outcome = PopupPolicy.outcome(for: request(to: address), openerZone: .today)
            #expect(outcome == PopupOutcome(decision: .popupPanel), "\(address)")
        }
    }

    @Test func otherPagesOfThoseSitesStillOpenTabs() {
        for address in [
            "https://github.com/",
            "https://github.com/login",
            "https://github.com/login/oauthx",
            "https://github.com/someone/login/oauth",
            "http://accounts.google.com/",
            "https://google.com/",
            "https://accounts.google.com.example.com/",
            "https://example.com/?next=https://accounts.google.com/",
        ] {
            #expect(PopupPolicy.outcome(for: request(to: address), openerZone: .today).decision == .foregroundTab)
            #expect(!PopupPolicy.isIdentityProvider(URL(string: address)), "\(address)")
        }
        #expect(!PopupPolicy.isIdentityProvider(nil))
    }

    @Test func identityProviderPagesFromAModifiedClickOrNoClickDoNotOpenAPanel() {
        let address = "https://accounts.google.com/signin"
        let command = request(to: address, modifiers: .init(command: true))
        #expect(PopupPolicy.outcome(for: command, openerZone: .today).decision == .backgroundTab)
        let shift = request(to: address, modifiers: .init(shift: true))
        #expect(PopupPolicy.outcome(for: shift, openerZone: .today).decision == .peek)
        let noClick = request(to: address, gesture: false)
        #expect(PopupPolicy.outcome(for: noClick, openerZone: .today).decision == .block)
    }

    @Test func aPanelHasNoTabPlacement() {
        let sized = request(features: .init(width: 480, height: 560))
        #expect(PopupPolicy.outcome(for: sized, openerZone: .favorite).placement == nil)
    }
}

@Suite struct PopupPanelLayoutTests {
    let window = CGSize(width: 1200, height: 800)

    func sized(width: Int? = nil, height: Int? = nil, asked: PopupSize? = nil) -> PopupRequest {
        PopupRequest(
            targetURL: nil, disposition: .popup, isUserGesture: true, requestedSize: asked,
            windowFeatures: PopupWindowFeatures(width: width, height: height, isPopup: true))
    }

    @Test func usesTheSizeThePageAskedFor() {
        #expect(
            PopupPanelLayout.contentSize(for: sized(width: 480, height: 560), within: window)
                == CGSize(width: 480, height: 560))
        let asked = sized(asked: PopupSize(width: 400, height: 500))
        #expect(PopupPanelLayout.contentSize(for: asked, within: window) == CGSize(width: 400, height: 500))
    }

    @Test func fallsBackToTheDefaultForEachUnsetSide() {
        #expect(PopupPanelLayout.contentSize(for: sized(), within: window) == PopupPanelLayout.defaultSize)
        #expect(
            PopupPanelLayout.contentSize(for: sized(width: 450), within: window)
                == CGSize(width: 450, height: PopupPanelLayout.defaultSize.height))
    }

    @Test func staysInsideTheWindowAndAboveTheMinimum() {
        let huge = sized(width: 5000, height: 5000)
        #expect(PopupPanelLayout.contentSize(for: huge, within: window) == CGSize(width: 1160, height: 760))
        let tiny = sized(width: 10, height: 10)
        #expect(PopupPanelLayout.contentSize(for: tiny, within: window) == PopupPanelLayout.minimumSize)
        let smallWindow = CGSize(width: 200, height: 150)
        #expect(PopupPanelLayout.contentSize(for: huge, within: smallWindow) == PopupPanelLayout.minimumSize)
    }

    @Test func centersOverTheOpenerWindow() {
        let parent = CGRect(x: -3000, y: 100, width: 1200, height: 801)
        let frame = PopupPanelLayout.frame(size: CGSize(width: 480, height: 600), centeredIn: parent)
        #expect(frame == CGRect(x: -2640, y: 201, width: 480, height: 600))
    }
}
