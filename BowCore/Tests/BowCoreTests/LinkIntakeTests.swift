import Foundation
import Testing

@testable import BowCore

private func link(_ path: String) -> IncomingLink {
    IncomingLink(url: URL(string: "https://example.com/\(path)")!, source: nil)
}

@Suite struct LinkSourceTests {
    @Test func helperAppCountsAsItsParentApp() {
        let path = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
        #expect(LinkSource.appBundlePath(containing: path) == "/Applications/Slack.app")
    }

    @Test func appExecutableGivesItsApp() {
        #expect(
            LinkSource.appBundlePath(containing: "/System/Applications/Mail.app/Contents/MacOS/Mail")
                == "/System/Applications/Mail.app")
    }

    @Test func toolOutsideAnyAppHasNone() {
        #expect(LinkSource.appBundlePath(containing: "/usr/bin/open") == nil)
        #expect(LinkSource.appBundlePath(containing: "relative/Thing.app/x") == nil)
        #expect(LinkSource.appBundlePath(containing: "/opt/.app/x") == nil)
    }
}

@Suite struct IncomingLinkTests {
    @Test func acceptsWebAddresses() {
        #expect(
            IncomingLink(text: " https://example.com/a\n", source: nil)?.url.absoluteString == "https://example.com/a")
        #expect(IncomingLink(text: "HTTP://Example.com", source: nil) != nil)
    }

    @Test func refusesOtherOrMalformedAddresses() {
        for text in ["", "mailto:a@b.c", "file:///etc/hosts", "https://", "http:///path", "not a url", "javascript:1"] {
            #expect(IncomingLink(text: text, source: nil) == nil, "\(text)")
        }
    }
}

@Suite struct LinkIntakeTests {
    @Test func keepsEarlyLinksInOrderUntilOpen() {
        var intake = LinkIntake()
        #expect(intake.receive(link("1")) == nil)
        #expect(intake.receive(link("2")) == nil)
        #expect(intake.open() == [link("1"), link("2")])
        #expect(intake.pending.isEmpty)
        #expect(intake.open().isEmpty)
        #expect(intake.receive(link("3")) == link("3"))
    }

    @Test func refusalDropsKeptAndLaterLinks() {
        var intake = LinkIntake()
        _ = intake.receive(link("1"))
        intake.refuse()
        #expect(intake.pending.isEmpty)
        #expect(intake.receive(link("2")) == nil)
        #expect(intake.open().isEmpty)
        #expect(intake.state == .refused)
    }
}
