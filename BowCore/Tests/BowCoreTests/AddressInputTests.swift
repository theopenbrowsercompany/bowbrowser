import Foundation
import Testing

@testable import BowCore

@Suite struct AddressInputTests {
    @Test func keepsFullURLs() {
        #expect(AddressInput.resolve("https://arc.net/features")?.absoluteString == "https://arc.net/features")
        #expect(AddressInput.resolve("about:blank")?.absoluteString == "about:blank")
    }

    @Test func addsHTTPSToHostNames() {
        #expect(AddressInput.resolve("example.com")?.absoluteString == "https://example.com")
        #expect(AddressInput.resolve("  example.com/docs ")?.absoluteString == "https://example.com/docs")
        #expect(AddressInput.resolve("localhost:8080")?.absoluteString == "https://localhost:8080")
    }

    @Test func searchesEverythingElse() {
        let search = AddressInput.resolve("swift concurrency")?.absoluteString
        #expect(search == AddressInput.searchURL + "swift%20concurrency")
        #expect(AddressInput.resolve("arc")?.absoluteString == AddressInput.searchURL + "arc")
    }

    @Test func ignoresBlankInput() {
        #expect(AddressInput.resolve("   ") == nil)
    }
}
