import BowCore
import Foundation
import Testing

@Suite struct AddressDisplayTests {
    private func text(_ address: String?) -> String? {
        AddressDisplay.text(for: address.flatMap(URL.init(string:)))
    }

    @Test func webPagesShowTheirHostAndPath() {
        #expect(text("https://notes.example.com/roadmap?tab=2#q3") == "notes.example.com/roadmap")
        #expect(text("https://notes.example.com/roadmap") == "notes.example.com/roadmap")
        #expect(text("HTTPS://WWW.Example.COM/a/b") == "example.com/a/b")
        #expect(text("https://bow.test/chrome/page.html") == "bow.test/chrome/page.html")
    }

    @Test func aRootAddressShowsTheHostAlone() {
        #expect(text("http://example.com") == "example.com")
        #expect(text("https://example.com/") == "example.com")
        #expect(text("https://www.example.com/?q=1#top") == "example.com")
    }

    @Test func aTrailingSlashOnADeeperPathIsDropped() {
        #expect(text("ftp://ftp.example.com/pub/") == "ftp.example.com/pub")
        #expect(text("https://example.com/a/b/") == "example.com/a/b")
    }

    @Test func onlyAnOddPortIsShown() {
        #expect(text("http://localhost:3000/app") == "localhost:3000/app")
        #expect(text("https://example.com:443/") == "example.com")
        #expect(text("http://example.com:80/") == "example.com")
        #expect(text("https://example.com:8443/") == "example.com:8443")
        #expect(text("http://[::1]:8080/") == "[::1]:8080")
    }

    @Test func aHostNamedWwwKeepsItsName() {
        #expect(text("https://www./") == "www.")
        #expect(text("https://www.com/") == "www.com")
    }

    @Test func localFilesShowTheirName() {
        #expect(text("file:///tmp/Documents/report.pdf") == "report.pdf")
        #expect(text("file:///") == "/")
    }

    @Test func blankAndInternalPagesShowThePlaceholder() {
        #expect(text(nil) == nil)
        #expect(text("about:blank") == nil)
        #expect(text("chrome://settings") == nil)
        #expect(text("devtools://devtools/bundled/inspector.html") == nil)
        #expect(text("data:text/html,hi") == nil)
        #expect(text("javascript:alert(1)") == nil)
        #expect(AddressDisplay.placeholder == "Search or type a URL")
    }
}
