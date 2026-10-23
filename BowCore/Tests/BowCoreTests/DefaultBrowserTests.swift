import BowCore
import Foundation
import Testing

@Suite struct DefaultBrowserTests {
    private let bow = URL(fileURLWithPath: "/tmp/Apps/Bow.app")

    @Test func registersHttpThenHttps() {
        #expect(DefaultBrowser.schemes == ["http", "https"])
        #expect(DefaultBrowser.probeScheme == "http")
    }

    @Test func defaultOnlyWhenTheHandlerIsThisApp() {
        #expect(DefaultBrowser.isDefault(handler: bow, bundleURL: bow))
        #expect(!DefaultBrowser.isDefault(handler: URL(fileURLWithPath: "/tmp/Apps/Other.app"), bundleURL: bow))
        #expect(!DefaultBrowser.isDefault(handler: nil, bundleURL: bow))
    }

    @Test func pathsCompareByLocation() {
        #expect(DefaultBrowser.isDefault(handler: URL(fileURLWithPath: "/tmp/Apps/Bow.app/"), bundleURL: bow))
        #expect(DefaultBrowser.isDefault(handler: URL(fileURLWithPath: "/tmp/Apps/../Apps/Bow.app"), bundleURL: bow))
        // /tmp is a link to /private/tmp.
        #expect(DefaultBrowser.isDefault(handler: URL(fileURLWithPath: "/private/tmp/Apps/Bow.app"), bundleURL: bow))
        #expect(!DefaultBrowser.isDefault(handler: URL(fileURLWithPath: "/tmp/Apps/Bow.app.old"), bundleURL: bow))
        #expect(!DefaultBrowser.isDefault(handler: URL(string: "https://example.com/tmp/Apps/Bow.app"), bundleURL: bow))
    }

    @Test func titlesFollowTheDefault() {
        #expect(DefaultBrowser.title(isDefault: false) == "Set as Default Browser…")
        #expect(DefaultBrowser.title(isDefault: true) == "Bow Is Your Default Browser")
    }

    @Test func enabledOnlyWhenNotDefaultAndIdle() {
        #expect(DefaultBrowser.isEnabled(isDefault: false, registering: false))
        #expect(!DefaultBrowser.isEnabled(isDefault: true, registering: false))
        #expect(!DefaultBrowser.isEnabled(isDefault: false, registering: true))
        #expect(!DefaultBrowser.isEnabled(isDefault: true, registering: true))
    }

    @Test func cancellingThePromptShowsNoAlert() {
        let cancelled = DefaultBrowser.Failure(domain: NSCocoaErrorDomain, code: NSUserCancelledError, message: "x")
        #expect(DefaultBrowser.isCancellation(cancelled))
        #expect(DefaultBrowser.alert(for: cancelled, scheme: "http") == nil)
    }

    @Test func otherFailuresShowAnAlertNamingTheScheme() throws {
        let failure = DefaultBrowser.Failure(domain: "Launch", code: 7, message: "Not permitted.")
        let alert = try #require(DefaultBrowser.alert(for: failure, scheme: "https"))
        #expect(alert.title == "Bow could not be set as your default browser")
        #expect(alert.detail.contains("https") && alert.detail.contains("Not permitted."))
        let otherDomain = DefaultBrowser.Failure(domain: "Other", code: NSUserCancelledError, message: "")
        #expect(!DefaultBrowser.isCancellation(otherDomain))
        #expect(try #require(DefaultBrowser.alert(for: otherDomain, scheme: "http")).detail.contains("no reason"))
    }
}
