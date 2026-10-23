import BowCore
import Foundation
import Testing

@Suite struct SignInPolicyTests {
    typealias Policy = SignInPolicy<String>

    let challenge = AuthChallenge(
        url: URL(string: "http://auth.bow.test/"), host: "auth.bow.test", port: 80, realm: "bow", scheme: "basic")
    let credentials = AuthCredentials(user: "bow", password: "secret")

    @Test func shownTabRequestComesUpAndIsAnsweredOnce() {
        var policy = Policy(shownTab: "a")
        let (id, actions) = policy.request(challenge, from: "a")
        #expect(actions == [.present(id)])
        #expect(policy.presented == id)
        #expect(policy.challenge(id) == challenge)
        #expect(policy.answered(id, credentials) == [.answer(id, credentials)])
        #expect(policy.answered(id, credentials) == [])
        #expect(policy.isEmpty)
        #expect(!policy.hasRequest(for: "a"))
    }

    @Test func cancelAnswersNil() {
        var policy = Policy(shownTab: "a")
        let (id, _) = policy.request(challenge, from: "a")
        #expect(policy.answered(id, nil) == [.answer(id, nil)])
        #expect(policy.isEmpty)
    }

    @Test func hiddenTabRequestWaitsUnansweredUntilItsTabIsShown() {
        var policy = Policy(shownTab: "a")
        let (id, actions) = policy.request(challenge, from: "b")
        #expect(actions == [])
        #expect(policy.presented == nil)
        #expect(policy.hasRequest(for: "b"))
        // An answer for a sheet that is not up is ignored.
        #expect(policy.answered(id, credentials) == [])
        #expect(policy.show("b") == [.present(id)])
        #expect(policy.answered(id, credentials) == [.answer(id, credentials)])
    }

    @Test func switchingAwayKeepsTheRequestWaitingAndBringsItBack() {
        var policy = Policy(shownTab: "a")
        let (id, _) = policy.request(challenge, from: "a")
        #expect(policy.show("b") == [.dismiss(id)])
        #expect(policy.presented == nil)
        #expect(policy.hasRequest(for: "a"))
        #expect(policy.show("a") == [.present(id)])
        #expect(policy.show(nil) == [.dismiss(id)])
        #expect(policy.show("a") == [.present(id)])
    }

    @Test func showingTheSameTabAgainDoesNothing() {
        var policy = Policy(shownTab: "a")
        let (_, _) = policy.request(challenge, from: "a")
        #expect(policy.show("a") == [])
    }

    @Test func twoTabsAskAtOnce() {
        var policy = Policy(shownTab: "a")
        let (first, _) = policy.request(challenge, from: "a")
        let (second, actions) = policy.request(challenge, from: "b")
        #expect(actions == [])
        #expect(policy.show("b") == [.dismiss(first), .present(second)])
        #expect(policy.answered(second, credentials) == [.answer(second, credentials)])
        #expect(policy.show("a") == [.present(first)])
        #expect(policy.answered(first, nil) == [.answer(first, nil)])
        #expect(policy.isEmpty)
    }

    @Test func aNewRequestFromTheTabReplacesItsEarlierOne() {
        var policy = Policy(shownTab: "a")
        let (first, _) = policy.request(challenge, from: "a")
        let (second, actions) = policy.request(challenge, from: "a")
        #expect(actions == [.dismiss(first), .answer(first, nil), .present(second)])
        #expect(policy.presented == second)
        #expect(policy.answered(first, credentials) == [])
    }

    @Test func aWrongPasswordAsksAgain() {
        var policy = Policy(shownTab: "a")
        let (first, _) = policy.request(challenge, from: "a")
        let wrong = AuthCredentials(user: "bow", password: "wrong")
        #expect(policy.answered(first, wrong) == [.answer(first, wrong)])
        let (second, actions) = policy.request(challenge, from: "a")
        #expect(actions == [.present(second)])
        #expect(policy.answered(second, credentials) == [.answer(second, credentials)])
    }

    @Test func navigatingCancelsTheTabsRequestOnly() {
        var policy = Policy(shownTab: "a")
        let (shown, _) = policy.request(challenge, from: "a")
        let (hidden, _) = policy.request(challenge, from: "b")
        #expect(policy.navigated("b") == [.answer(hidden, nil)])
        #expect(policy.navigated("a") == [.dismiss(shown), .answer(shown, nil)])
        #expect(policy.navigated("a") == [])
        #expect(policy.isEmpty)
    }

    @Test func closingTheShownTabCancelsAndForgetsIt() {
        var policy = Policy(shownTab: "a")
        let (id, _) = policy.request(challenge, from: "a")
        #expect(policy.closed("a") == [.dismiss(id), .answer(id, nil)])
        #expect(policy.shownTab == nil)
        #expect(policy.answered(id, credentials) == [])
    }

    @Test func closingAHiddenTabCancelsWithoutTouchingTheSheet() {
        var policy = Policy(shownTab: "a")
        let (shown, _) = policy.request(challenge, from: "a")
        let (hidden, _) = policy.request(challenge, from: "b")
        #expect(policy.closed("b") == [.answer(hidden, nil)])
        #expect(policy.presented == shown)
        #expect(policy.shownTab == "a")
    }

    @Test func closeAllCancelsEverythingAndEveryLaterRequest() {
        var policy = Policy(shownTab: "a")
        let (shown, _) = policy.request(challenge, from: "a")
        let (hidden, _) = policy.request(challenge, from: "b")
        #expect(policy.closeAll() == [.dismiss(shown), .answer(shown, nil), .answer(hidden, nil)])
        #expect(policy.closeAll() == [])
        let (late, actions) = policy.request(challenge, from: "a")
        #expect(actions == [.answer(late, nil)])
        #expect(policy.show("a") == [])
        #expect(policy.isEmpty)
    }

    @Test func sheetNamesTheHostAndRealm() {
        #expect(AuthChallenge.sheetTitle == "Sign in")
        let secure = AuthChallenge(
            url: URL(string: "https://intranet.example/"), host: "intranet.example", port: 443, realm: "Staff",
            scheme: "basic")
        #expect(secure.sheetMessage == "intranet.example asks for a user name and password for \u{201C}Staff\u{201D}.")
        #expect(
            challenge.sheetMessage
                == "auth.bow.test asks for a user name and password for \u{201C}bow\u{201D}. "
                + "Your connection to this site is not private.")
    }

    @Test func sheetShowsAnUnusualPortAndLeavesOutAnEmptyRealm() {
        let other = AuthChallenge(
            url: URL(string: "https://intranet.example:8443/"), host: "intranet.example", port: 8443, realm: " ",
            scheme: "digest")
        #expect(other.sheetMessage == "intranet.example:8443 asks for a user name and password.")
        let noURL = AuthChallenge(url: nil, host: "intranet.example", port: 80, realm: "", scheme: "basic")
        #expect(noURL.sheetMessage == "intranet.example asks for a user name and password.")
    }

    @Test func sheetNamesAProxyWithItsPort() {
        let proxy = AuthChallenge(
            url: URL(string: "https://site.example/"), host: "proxy.example", port: 3128, realm: "corp",
            scheme: "basic", isProxy: true)
        #expect(proxy.sheetMessage == "The proxy proxy.example:3128 asks for a user name and password.")
    }

    @Test func sheetCutsALongOrMultilineRealm() {
        let long = String(repeating: "x", count: 200)
        let challenge = AuthChallenge(
            url: URL(string: "https://a.example/"), host: "a.example", port: 443, realm: long, scheme: "basic")
        let quoted = String(repeating: "x", count: AuthChallenge.maxShownRealmLength - 1) + "\u{2026}"
        #expect(challenge.sheetMessage == "a.example asks for a user name and password for \u{201C}\(quoted)\u{201D}.")
        let multiline = AuthChallenge(
            url: URL(string: "https://a.example/"), host: "a.example", port: 443, realm: "one\ntwo", scheme: "basic")
        #expect(multiline.sheetMessage == "a.example asks for a user name and password for \u{201C}one two\u{201D}.")
    }
}
