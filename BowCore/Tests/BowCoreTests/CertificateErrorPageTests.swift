import BowCore
import Foundation
import Testing

@Suite struct CertificateErrorPageTests {
    let url = URL(string: "https://badcert.bow.test/")!

    @Test func pageNamesTheHostAndTheErrorInPlainWords() {
        let page = CertificateErrorPage(error: CertificateError(url: url, reason: .untrustedAuthority))
        #expect(CertificateErrorPage.title == "This connection is not secure")
        #expect(CertificateErrorPage.goBackTitle == "Go back")
        #expect(page.host == "badcert.bow.test")
        #expect(
            page.message
                == "Bow could not confirm that this is the real badcert.bow.test. "
                + "Its certificate is not from an authority this Mac trusts. "
                + "Someone might be trying to steal what you send to it, such as passwords, messages or card numbers.")
        #expect(page.errorName == "NET::ERR_CERT_AUTHORITY_INVALID")
    }

    @Test func eachReasonHasItsSentenceAndChromesName() {
        let expected: [CertificateError.Reason: (String, String)] = [
            .nameMismatch: ("Its certificate belongs to a different site.", "NET::ERR_CERT_COMMON_NAME_INVALID"),
            .dateInvalid: ("Its certificate has expired or is not valid yet.", "NET::ERR_CERT_DATE_INVALID"),
            .untrustedAuthority: (
                "Its certificate is not from an authority this Mac trusts.", "NET::ERR_CERT_AUTHORITY_INVALID"
            ),
            .containsErrors: ("Its certificate contains errors.", "NET::ERR_CERT_CONTAINS_ERRORS"),
            .noRevocationMechanism: (
                "Its certificate could not be checked for revocation.", "NET::ERR_CERT_NO_REVOCATION_MECHANISM"
            ),
            .unableToCheckRevocation: (
                "Its certificate could not be checked for revocation.", "NET::ERR_CERT_UNABLE_TO_CHECK_REVOCATION"
            ),
            .revoked: ("Its certificate has been revoked by the authority that issued it.", "NET::ERR_CERT_REVOKED"),
            .invalid: ("Its certificate is not valid.", "NET::ERR_CERT_INVALID"),
            .weakSignature: ("Its certificate uses a weak signature.", "NET::ERR_CERT_WEAK_SIGNATURE_ALGORITHM"),
            .nonUniqueName: ("Its certificate names a site that is not unique.", "NET::ERR_CERT_NON_UNIQUE_NAME"),
            .weakKey: ("Its certificate uses a weak key.", "NET::ERR_CERT_WEAK_KEY"),
            .nameConstraintViolation: (
                "Its certificate names a site its authority may not certify.", "NET::ERR_CERT_NAME_CONSTRAINT_VIOLATION"
            ),
            .validityTooLong: ("Its certificate is valid for longer than allowed.", "NET::ERR_CERT_VALIDITY_TOO_LONG"),
            .notPubliclyLogged: (
                "Its certificate was not publicly logged.", "NET::ERR_CERTIFICATE_TRANSPARENCY_REQUIRED"
            ),
            .distrustedAuthority: (
                "Its certificate is from an authority that is no longer trusted.", "NET::ERR_CERT_SYMANTEC_LEGACY"
            ),
            .selfSignedLocalNetwork: (
                "Its certificate is self-signed on the local network.", "NET::ERR_CERT_SELF_SIGNED_LOCAL_NETWORK"
            ),
            .other: ("Its certificate could not be verified.", "NET::ERR_CERT_INVALID"),
        ]
        #expect(Set(expected.keys) == Set(CertificateError.Reason.allCases))
        for reason in CertificateError.Reason.allCases {
            let page = CertificateErrorPage(error: CertificateError(url: url, reason: reason))
            #expect(page.reason == expected[reason]?.0, "\(reason)")
            #expect(page.errorName == expected[reason]?.1, "\(reason)")
            #expect(page.message.contains(page.reason))
        }
        // Every known reason has a name of its own; only an unknown one shares the generic name.
        let known = CertificateError.Reason.allCases.filter { $0 != .other }
        #expect(Set(known.compactMap { expected[$0]?.1 }).count == known.count)
    }

    @Test func unknownReasonAndMissingHostStayPlain() {
        let page = CertificateErrorPage(error: CertificateError(url: nil, reason: .other))
        #expect(page.host == "this site")
        #expect(page.reason == "Its certificate could not be verified.")
        #expect(page.errorName == "NET::ERR_CERT_INVALID")
        #expect(page.message.hasPrefix("Bow could not confirm that this is the real this site."))
    }

    @Test func theURLFieldShowsTheFailedAddressAsNotSecure() {
        let page = CertificateErrorPage(
            error: CertificateError(url: URL(string: "https://www.badcert.bow.test/a?b")!, reason: .untrustedAuthority))
        #expect(page.addressLine == AddressLine(text: "badcert.bow.test/a", security: .notSecure))
        // With no address the field shows its placeholder, still marked not secure.
        let bare = CertificateErrorPage(error: CertificateError(url: nil, reason: .untrustedAuthority))
        #expect(bare.addressLine == AddressLine(text: nil, security: .notSecure))
        #expect(AddressLine.tab(URL(string: "https://bow.test/auth/")) == AddressLine(text: "bow.test/auth"))
        #expect(AddressLine.tab(nil).security == .standard)
    }

    @Test func thePageTakesTheKeyboardOnlyFromItsOwnPaneOrNothing() {
        #expect(CertificateErrorPage.takesKeyboard(from: .coveredPage, inFocusedPane: true))
        #expect(CertificateErrorPage.takesKeyboard(from: .nothing, inFocusedPane: true))
        // Never from a field being typed in (the command bar), nor from the sidebar or another pane.
        #expect(!CertificateErrorPage.takesKeyboard(from: .textField, inFocusedPane: true))
        #expect(!CertificateErrorPage.takesKeyboard(from: .elsewhere, inFocusedPane: true))
        // A pane without focus never takes it, whatever holds it.
        #expect(!CertificateErrorPage.takesKeyboard(from: .coveredPage, inFocusedPane: false))
        #expect(!CertificateErrorPage.takesKeyboard(from: .nothing, inFocusedPane: false))
    }

    @Test func returnAndEnterPressGoBackWithoutMenuModifiers() {
        #expect(CertificateErrorPage.pressesGoBack(characters: "\r", commandOptionOrControl: false))
        #expect(CertificateErrorPage.pressesGoBack(characters: "\u{3}", commandOptionOrControl: false))
        #expect(!CertificateErrorPage.pressesGoBack(characters: "\r", commandOptionOrControl: true))
        #expect(!CertificateErrorPage.pressesGoBack(characters: " ", commandOptionOrControl: false))
        #expect(!CertificateErrorPage.pressesGoBack(characters: "a", commandOptionOrControl: false))
        #expect(!CertificateErrorPage.pressesGoBack(characters: nil, commandOptionOrControl: false))
    }

    @Test func goBackUsesHistoryOrClosesTheTab() {
        #expect(CertificateErrorPage.goBack(canGoBack: true, isLoading: false) == .history)
        #expect(CertificateErrorPage.goBack(canGoBack: false, isLoading: false) == .closeTab)
        // Before the failed load settles, the history still ends at the page before it, so neither is known.
        #expect(CertificateErrorPage.goBack(canGoBack: false, isLoading: true) == .waitForLoad)
        #expect(CertificateErrorPage.goBack(canGoBack: true, isLoading: true) == .waitForLoad)
    }

    @Test func aTabShowsThePageUntilItsNextNavigation() {
        var pages = CertificateErrorPages<String>()
        let error = CertificateError(url: url, reason: .untrustedAuthority)
        pages.navigationStarted("a", to: url)
        let shown = pages.certificateFailed("a", error)
        #expect(shown)
        #expect(pages.page(for: "a") == CertificateErrorPage(error: error))
        #expect(pages.page(for: "b") == nil)
        pages.navigationStarted("a", to: URL(string: "https://bow.test/")!)
        #expect(pages.page(for: "a") == nil)
    }

    @Test func aLateErrorForANavigationTheTabLeftShowsNothing() {
        var pages = CertificateErrorPages<String>()
        pages.navigationStarted("a", to: url)
        pages.navigationStarted("a", to: URL(string: "https://bow.test/")!)
        let late = pages.certificateFailed("a", CertificateError(url: url, reason: .untrustedAuthority))
        #expect(!late)
        #expect(pages.page(for: "a") == nil)
        let otherTab = pages.certificateFailed("b", CertificateError(url: url, reason: .untrustedAuthority))
        let noURL = pages.certificateFailed("a", CertificateError(url: nil, reason: .untrustedAuthority))
        #expect(!otherTab && !noURL)
    }

    @Test func aRedirectMovesTheNavigationAndHostsCompareLoosely() {
        var pages = CertificateErrorPages<String>()
        pages.navigationStarted("a", to: URL(string: "http://badcert.bow.test/")!)
        pages.redirected("a", to: URL(string: "https://BadCert.bow.test./login")!)
        let shown = pages.certificateFailed("a", CertificateError(url: url, reason: .untrustedAuthority))
        #expect(shown)
        pages.redirected("a", to: URL(string: "https://other.test/")!)
        #expect(pages.page(for: "a") != nil)
    }

    @Test func forgettingATabClearsIt() {
        var pages = CertificateErrorPages<String>()
        pages.navigationStarted("a", to: url)
        pages.certificateFailed("a", CertificateError(url: url, reason: .untrustedAuthority))
        pages.forget("a")
        #expect(pages.page(for: "a") == nil)
        #expect(pages.isEmpty)
    }
}
