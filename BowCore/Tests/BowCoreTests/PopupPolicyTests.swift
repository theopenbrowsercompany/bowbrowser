import BowCore
import Foundation
import Testing

@Suite struct PopupPolicyTests {
    let url = URL(string: "https://example.com/")!

    func request(
        gesture: Bool = true, disposition: PopupDisposition = .foregroundTab, features: PopupWindowFeatures = .init()
    ) -> PopupRequest {
        PopupRequest(targetURL: url, disposition: disposition, isUserGesture: gesture, windowFeatures: features)
    }

    @Test func noGestureIsBlocked() {
        let outcome = PopupPolicy.outcome(for: request(gesture: false), openerZone: .today)
        #expect(outcome == PopupOutcome(decision: .block))
    }

    @Test func sizedPopupStaysAWindow() {
        let sized = request(disposition: .popup, features: .init(width: 500, height: 600, isPopup: true))
        #expect(PopupPolicy.outcome(for: sized, openerZone: .today) == PopupOutcome(decision: .window))
        let widthOnly = request(features: .init(width: 500))
        #expect(PopupPolicy.outcome(for: widthOnly, openerZone: .pinned).decision == .window)
    }

    @Test func targetBlankOpensInTheBackgroundAfterTheOpener() {
        let outcome = PopupPolicy.outcome(for: request(), openerZone: .today)
        #expect(outcome == PopupOutcome(decision: .backgroundTab, placement: .afterOpener))
    }

    @Test func commandClickOpensInTheBackgroundAfterTheOpener() {
        let outcome = PopupPolicy.outcome(
            for: request(disposition: .backgroundTab), openerZone: .today, modifiers: .init(command: true))
        #expect(outcome == PopupOutcome(decision: .backgroundTab, placement: .afterOpener))
    }

    @Test func commandShiftClickOpensInTheForegroundAfterTheOpener() {
        let outcome = PopupPolicy.outcome(
            for: request(), openerZone: .today, modifiers: .init(command: true, shift: true))
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .afterOpener))
    }

    @Test func shiftClickOpensInTheForeground() {
        let outcome = PopupPolicy.outcome(
            for: request(disposition: .window), openerZone: .today, modifiers: .init(shift: true))
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .afterOpener))
    }

    @Test func fromPinnedGoesToTopOfToday() {
        let outcome = PopupPolicy.outcome(for: request(), openerZone: .pinned)
        #expect(outcome == PopupOutcome(decision: .backgroundTab, placement: .topOfToday))
    }

    @Test func fromFavoriteGoesToTopOfToday() {
        let outcome = PopupPolicy.outcome(
            for: request(), openerZone: .favorite, modifiers: .init(command: true, shift: true))
        #expect(outcome == PopupOutcome(decision: .foregroundTab, placement: .topOfToday))
    }

    @Test func fromTodayGoesAfterTheOpener() {
        #expect(PopupPolicy.outcome(for: request(), openerZone: .today).placement == .afterOpener)
    }
}
