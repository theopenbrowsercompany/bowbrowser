import BowCore
import Foundation
import Testing

@Suite struct PageDialogPolicyTests {
    typealias Policy = PageDialogPolicy<String>

    func dialog(_ kind: PageDialogKind, _ message: String = "hi") -> PageDialog {
        PageDialog(kind: kind, origin: URL(string: "https://bow.test/page"), message: message)
    }

    @Test func shownTabDialogsComeUpAndWaitForTheirAnswer() {
        for kind in [PageDialogKind.alert, .confirm, .prompt] {
            var policy = Policy(shownTab: "a")
            let (id, actions) = policy.request(dialog(kind), from: "a")
            #expect(actions == [.present(id)])
            #expect(policy.presented == id)
            #expect(policy.dialog(id) == dialog(kind))
            let answer = PageDialogAnswer(accepted: true, text: kind == .prompt ? "typed" : nil)
            #expect(policy.answered(id, answer) == [.answer(id, answer)])
            #expect(policy.presented == nil)
            #expect(!policy.hasDialog(for: "a"))
        }
    }

    @Test func backgroundAlertIsAnsweredAtOnceAndComesUpWhenItsTabIsShown() {
        var policy = Policy(shownTab: "a")
        let (id, actions) = policy.request(dialog(.alert), from: "b")
        #expect(actions == [.answer(id, .ok)])
        #expect(policy.presented == nil)
        #expect(policy.hasDialog(for: "b"))
        #expect(policy.show("b") == [.present(id)])
        // The page already has its answer: closing the sheet answers nothing again.
        #expect(policy.answered(id, .ok) == [])
        #expect(!policy.hasDialog(for: "b"))
    }

    @Test func backgroundConfirmAndPromptAreCancelledAtOnce() {
        for kind in [PageDialogKind.confirm, .prompt] {
            var policy = Policy(shownTab: "a")
            let (id, actions) = policy.request(dialog(kind), from: "b")
            #expect(actions == [.answer(id, .cancelled)])
            #expect(!policy.hasDialog(for: "b"))
            #expect(policy.show("b") == [])
        }
    }

    @Test func switchingAwayAnswersAnAlertAndBringsItBack() {
        var policy = Policy(shownTab: "a")
        let (id, _) = policy.request(dialog(.alert), from: "a")
        #expect(policy.show("b") == [.dismiss(id), .answer(id, .ok)])
        #expect(policy.show("a") == [.present(id)])
        #expect(policy.show("b") == [.dismiss(id)])
    }

    @Test func switchingAwayCancelsAConfirmOrPrompt() {
        for kind in [PageDialogKind.confirm, .prompt] {
            var policy = Policy(shownTab: "a")
            let (id, _) = policy.request(dialog(kind), from: "a")
            #expect(policy.show("b") == [.dismiss(id), .answer(id, .cancelled)])
            #expect(policy.show("a") == [])
        }
    }

    @Test func aNewDialogReplacesTheTabsEarlierOne() {
        var policy = Policy(shownTab: "a")
        let (first, _) = policy.request(dialog(.confirm, "one"), from: "a")
        let (second, actions) = policy.request(dialog(.prompt, "two"), from: "a")
        #expect(actions == [.dismiss(first), .answer(first, .cancelled), .present(second)])
        #expect(policy.answered(first, .ok) == [])
        #expect(policy.presented == second)
    }

    @Test func twoTabsKeepTheirOwnDialogs() {
        var policy = Policy(shownTab: "a")
        let (shown, _) = policy.request(dialog(.confirm), from: "a")
        let (waiting, _) = policy.request(dialog(.alert), from: "b")
        #expect(policy.presented == shown)
        #expect(policy.show("b") == [.dismiss(shown), .answer(shown, .cancelled), .present(waiting)])
    }

    @Test func tabClosedWhileADialogWaitsOrIsUp() {
        var policy = Policy(shownTab: "a")
        _ = policy.request(dialog(.alert), from: "b")
        // The waiting alert's page has its answer already; nothing is up, so nothing else happens.
        #expect(policy.closed("b") == [])
        #expect(!policy.hasDialog(for: "b"))
        #expect(policy.show("b") == [])
        let (up, actions) = policy.request(dialog(.prompt), from: "b")
        #expect(actions == [.present(up)])
        #expect(policy.closed("b") == [.dismiss(up), .answer(up, .cancelled)])
        #expect(policy.shownTab == nil)
        #expect(policy.answered(up, .ok) == [])
    }

    @Test func navigationCancelsTheTabsDialog() {
        var policy = Policy(shownTab: "a")
        let (id, _) = policy.request(dialog(.confirm), from: "a")
        #expect(policy.navigated("b") == [])
        #expect(policy.navigated("a") == [.dismiss(id), .answer(id, .cancelled)])
        #expect(policy.presented == nil)
    }

    @Test func windowClosedOrQuitCancelsEverythingAndLaterDialogs() {
        var policy = Policy(shownTab: "a")
        let (up, _) = policy.request(dialog(.prompt), from: "a")
        let (waiting, _) = policy.request(dialog(.alert), from: "b")
        #expect(policy.closeAll() == [.dismiss(up), .answer(up, .cancelled)])
        #expect(!policy.hasDialog(for: "b"))
        let (late, actions) = policy.request(dialog(.alert), from: "a")
        #expect(actions == [.answer(late, .cancelled)])
        #expect(policy.show("b") == [])
        _ = waiting
    }

    // MARK: Panes

    @Test func aDialogFromAnUnfocusedPaneComesUpAtOnce() {
        var policy = Policy()
        _ = policy.show(["a", "b"])
        let (id, actions) = policy.request(dialog(.confirm), from: "b")
        #expect(actions == [.present(id)])
        #expect(policy.tab(of: id) == "b")
        #expect(policy.answered(id, .ok) == [.answer(id, .ok)])
    }

    @Test func aSecondPaneWaitsForTheSheetUnansweredAndComesUpNext() {
        var policy = Policy()
        _ = policy.show(["a", "b"])
        let (first, _) = policy.request(dialog(.alert), from: "a")
        let (second, actions) = policy.request(dialog(.prompt), from: "b")
        #expect(actions == [])
        #expect(policy.presented == first)
        #expect(policy.hasDialog(for: "b"))
        #expect(policy.answered(first, .ok) == [.answer(first, .ok), .present(second)])
        #expect(policy.presented == second)
    }

    @Test func aPaneLeavingTheScreenTakesItsWaitingDialogs() {
        var policy = Policy()
        _ = policy.show(["a", "b", "c"])
        let (up, _) = policy.request(dialog(.alert), from: "a")
        let (confirm, _) = policy.request(dialog(.confirm), from: "b")
        let (alert, _) = policy.request(dialog(.alert), from: "c")
        // b and c leave: b's waiting confirm is cancelled, c's waiting alert is answered and waits for c.
        #expect(policy.show(["a"]) == [.answer(confirm, .cancelled), .answer(alert, .ok)])
        #expect(policy.presented == up)
        #expect(!policy.hasDialog(for: "b"))
        #expect(policy.hasDialog(for: "c"))
        // a's sheet ends; c's alert comes up once c shows again.
        #expect(policy.answered(up, .ok) == [.answer(up, .ok)])
        #expect(policy.show(["a", "c"]) == [.present(alert)])
        #expect(policy.answered(alert, .ok) == [])
    }

    @Test func thePresentedPaneLeavingBringsUpTheNextPanesDialog() {
        var policy = Policy()
        _ = policy.show(["a", "b"])
        let (up, _) = policy.request(dialog(.prompt), from: "a")
        let (next, _) = policy.request(dialog(.confirm), from: "b")
        #expect(
            policy.show(["b"]) == [.dismiss(up), .answer(up, .cancelled), .present(next)])
        #expect(policy.presented == next)
    }

    @Test func aPaneClosingOrNavigatingWithItsSheetUpBringsUpTheNext() {
        var policy = Policy()
        _ = policy.show(["a", "b", "c"])
        let (up, _) = policy.request(dialog(.alert), from: "a")
        let (second, _) = policy.request(dialog(.alert), from: "b")
        let (third, _) = policy.request(dialog(.confirm), from: "c")
        #expect(policy.closed("a") == [.dismiss(up), .answer(up, .cancelled), .present(second)])
        #expect(policy.navigated("b") == [.dismiss(second), .answer(second, .cancelled), .present(third)])
        #expect(policy.closeAll() == [.dismiss(third), .answer(third, .cancelled)])
    }

    @Test func reorderedPanesChangeNothing() {
        var policy = Policy()
        _ = policy.show(["a", "b"])
        let (up, _) = policy.request(dialog(.confirm), from: "b")
        #expect(policy.show(["b", "a"]) == [])
        #expect(policy.presented == up)
    }

    @Test func titleNamesTheOrigin() {
        func title(_ origin: String?) -> String {
            PageDialog(kind: .alert, origin: origin.flatMap(URL.init(string:)), message: "").title
        }
        #expect(title("https://bow.test/a/b") == "bow.test says")
        #expect(title("http://example.com:80/") == "example.com says")
        #expect(title("https://example.com:8443/") == "example.com:8443 says")
        #expect(title("file:///tmp/a.html") == "This page says")
        #expect(title("data:text/html,hi") == "This page says")
        #expect(title(nil) == "This page says")
    }

    @Test func cancelledAnswerCarriesNoText() {
        #expect(PageDialogAnswer(accepted: false, text: "x").text == nil)
        #expect(PageDialogAnswer(accepted: true, text: "x").text == "x")
    }
}
