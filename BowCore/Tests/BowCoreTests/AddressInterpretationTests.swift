import Foundation
import Testing

@testable import BowCore

@Suite struct AddressInterpretationTests {
    @Test func classifiesInput() {
        #expect(AddressInput.interpret("").url == nil)
        #expect(AddressInput.interpret("https://arc.net") == .url(URL(string: "https://arc.net")!))
        #expect(AddressInput.interpret("example.com") == .host(URL(string: "https://example.com")!))
        #expect(!AddressInput.interpret("swift concurrency").isAddress)
        #expect(AddressInput.interpret("example.com").isAddress)
    }

    @Test func bareLocalhostIsAHost() {
        #expect(AddressInput.resolve("localhost")?.absoluteString == "https://localhost")
        #expect(AddressInput.resolve("LOCALHOST:3000/app")?.absoluteString == "https://LOCALHOST:3000/app")
    }

    @Test func ipv4AddressesAreHostsButNumbersAreSearches() {
        #expect(AddressInput.resolve("192.168.1.1:8080")?.absoluteString == "https://192.168.1.1:8080")
        #expect(AddressInput.resolve("3.14")?.absoluteString == AddressInput.searchURL + "3.14")
        #expect(AddressInput.resolve("999.1.1.1")?.absoluteString == AddressInput.searchURL + "999.1.1.1")
    }

    @Test func rejectsMalformedHosts() {
        #expect(!AddressInput.interpret("a..b").isAddress)
        #expect(!AddressInput.interpret("example.").isAddress)
        #expect(!AddressInput.interpret(".com").isAddress)
    }

    @Test func uppercaseSchemesAreKept() {
        #expect(AddressInput.interpret("HTTPS://Example.com") == .url(URL(string: "HTTPS://Example.com")!))
    }

    @Test func whitespaceInsideMakesASearch() {
        #expect(!AddressInput.interpret("example.com\tfoo").isAddress)
    }

    @Test func scriptSchemesAreSearches() {
        #expect(!AddressInput.interpret("javascript:alert(1)").isAddress)
    }

    @Test func searchEscapesCharactersThatWouldEndTheQuery() {
        let expected = AddressInput.searchURL + "a%26b%3Dc%2Bd%23e"
        #expect(AddressInput.resolve("a&b=c+d#e")?.absoluteString == expected)
    }

    @Test func schemeFollowedByWordsIsASearch() {
        #expect(!AddressInput.interpret("about: how to").isAddress)
        #expect(!AddressInput.interpret("file: report.pdf").isAddress)
    }

    @Test func emailsAndLeadingSlashesAreSearches() {
        #expect(!AddressInput.interpret("user@mail.com").isAddress)
        #expect(!AddressInput.interpret("/foo.bar").isAddress)
        #expect(!AddressInput.interpret("a?b.c").isAddress)
    }

    @Test func hostsMayCarryQueriesAndFragments() {
        #expect(AddressInput.interpret("example.com?q=1").isAddress)
        #expect(AddressInput.interpret("example.com#top").isAddress)
    }
}
