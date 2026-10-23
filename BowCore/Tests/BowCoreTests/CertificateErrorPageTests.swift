import BowCore
import Foundation
import Testing

@Suite struct CertificateErrorPageTests {
    let url = URL(string: "https://badcert.bow.test/")!

    @Test func pageNamesTheHostAndTheErrorInPlainWords() {
        let page = CertificateErrorPage(error: CertificateError(url: url, code: -202))
        #expect(CertificateErrorPage.title == "Your connection is not private")
        #expect(CertificateErrorPage.goBackTitle == "Go back")
        #expect(page.host == "badcert.bow.test")
        #expect(
            page.message
                == "Bow could not confirm that this is the real badcert.bow.test. "
                + "Its certificate is not from an authority this Mac trusts. "
                + "Someone might be trying to steal what you send to it, such as passwords, messages or card numbers.")
        #expect(page.errorName == "NET::ERR_CERT_AUTHORITY_INVALID")
    }

    @Test func eachKnownCodeHasItsOwnReasonAndName() {
        let codes = [-200, -201, -202, -203, -204, -206, -207, -208, -210, -211, -212, -213, -214, -217, -219]
        let pages = codes.map { CertificateErrorPage(error: CertificateError(url: url, code: $0)) }
        for page in pages {
            #expect(page.reason != "Its certificate could not be verified.")
            #expect(page.errorName.hasPrefix("NET::ERR_CERT"))
        }
        #expect(
            CertificateErrorPage(error: CertificateError(url: url, code: -201)).errorName
                == "NET::ERR_CERT_DATE_INVALID")
        #expect(
            CertificateErrorPage(error: CertificateError(url: url, code: -214)).errorName
                == "NET::ERR_CERTIFICATE_TRANSPARENCY_REQUIRED")
    }

    @Test func unknownCodeAndMissingHostStayPlain() {
        let page = CertificateErrorPage(error: CertificateError(url: nil, code: -299))
        #expect(page.host == "this site")
        #expect(page.reason == "Its certificate could not be verified.")
        #expect(page.errorName == "Error -299")
        #expect(page.message.hasPrefix("Bow could not confirm that this is the real this site."))
    }

    @Test func goBackUsesHistoryOrClosesTheTab() {
        #expect(CertificateErrorPage.goBack(canGoBack: true) == .history)
        #expect(CertificateErrorPage.goBack(canGoBack: false) == .closeTab)
    }

    @Test func aTabShowsThePageUntilItsNextNavigation() {
        var pages = CertificateErrorPages<String>()
        let error = CertificateError(url: url, code: -202)
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
        let late = pages.certificateFailed("a", CertificateError(url: url, code: -202))
        #expect(!late)
        #expect(pages.page(for: "a") == nil)
        let otherTab = pages.certificateFailed("b", CertificateError(url: url, code: -202))
        let noURL = pages.certificateFailed("a", CertificateError(url: nil, code: -202))
        #expect(!otherTab && !noURL)
    }

    @Test func aRedirectMovesTheNavigationAndHostsCompareLoosely() {
        var pages = CertificateErrorPages<String>()
        pages.navigationStarted("a", to: URL(string: "http://badcert.bow.test/")!)
        pages.redirected("a", to: URL(string: "https://BadCert.bow.test./login")!)
        let shown = pages.certificateFailed("a", CertificateError(url: url, code: -202))
        #expect(shown)
        pages.redirected("a", to: URL(string: "https://other.test/")!)
        #expect(pages.page(for: "a") != nil)
    }

    @Test func forgettingATabClearsIt() {
        var pages = CertificateErrorPages<String>()
        pages.navigationStarted("a", to: url)
        pages.certificateFailed("a", CertificateError(url: url, code: -202))
        pages.forget("a")
        #expect(pages.page(for: "a") == nil)
        #expect(pages.isEmpty)
    }
}
