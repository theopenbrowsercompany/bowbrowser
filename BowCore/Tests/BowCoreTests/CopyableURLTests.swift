import BowCore
import Foundation
import Testing

@Suite struct CopyableURLTests {
    private func address(_ text: String?) -> String? {
        CopyableURL.address(for: text.flatMap(URL.init(string:)))?.absoluteString
    }

    @Test func webPagesAreCopied() {
        #expect(address("https://example.com/a?b=1#c") == "https://example.com/a?b=1#c")
        #expect(address("HTTP://localhost:3000/") == "HTTP://localhost:3000/")
        #expect(address("file:///tmp/a.html") == "file:///tmp/a.html")
    }

    @Test func blankAndInternalPagesAreNot() {
        #expect(address(nil) == nil)
        #expect(address("about:blank") == nil)
        #expect(address("chrome://version") == nil)
        #expect(address("devtools://devtools/bundled/inspector.html") == nil)
        #expect(address("data:text/html,hi") == nil)
        #expect(address("javascript:alert(1)") == nil)
        #expect(address("https:") == nil)
    }
}
