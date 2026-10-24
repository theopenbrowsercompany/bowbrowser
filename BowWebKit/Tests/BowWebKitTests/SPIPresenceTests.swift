import Foundation
import ObjectiveC
import Testing
import WebKit

@testable import BowWebKit

/// Every private WebKit name Bow relies on is still there on the running macOS: each method answers `responds(to:)`
/// on its class, and each private callback is declared in WebKit's private delegate protocol. A WebKit release that
/// drops one fails here first, naming the entry and its fallback. Information entries are reported, not required.
/// Whether WebKit really calls a callback is tested by the slice that uses it.
@Suite @MainActor struct SPIPresenceTests {
    @Test(arguments: WebKitSPI.methods.filter(\.required).map(\.name))
    func methodIsPresent(_ name: String) throws {
        let entry = try #require(WebKitSPI.methods.first { $0.name == name })
        #expect(entry.kind == .method)
        #expect(WebKitSPI.isPresent(entry), "\(entry.owner) has no \(entry.name); fallback: \(entry.fallback)")
    }

    @Test(arguments: WebKitSPI.callbacks.filter { $0.required && $0.protocolReadable }.map(\.name))
    func callbackIsDeclared(_ name: String) throws {
        let entry = try #require(WebKitSPI.callbacks.first { $0.name == name })
        #expect(entry.kind == .callback)
        #expect(WebKitSPI.isPresent(entry), "\(entry.owner) declares no \(entry.name); fallback: \(entry.fallback)")
    }

    /// Information entries: their presence is recorded, never required.
    @Test func informationEntriesAreReported() {
        for entry in (WebKitSPI.methods + WebKitSPI.callbacks).filter({ !$0.required }) {
            print("SPI info: \(entry.name) on \(entry.owner) present=\(WebKitSPI.isPresent(entry)) (\(entry.use))")
        }
    }

    /// A callback whose protocol WebKit does not register is checked only by its slice's callback test; this says
    /// when WebKit starts registering one, so its entry can be checked here too.
    @Test func unreadableProtocolsAreStillUnregistered() {
        for entry in WebKitSPI.callbacks where !entry.protocolReadable {
            #expect(
                objc_getProtocol(entry.owner) == nil,
                "WebKit now registers \(entry.owner): set protocolReadable for \(entry.name)")
        }
    }

    /// Every entry names its use and its fallback, and no name is listed twice.
    @Test func everyEntryHasUseAndFallback() {
        let all = WebKitSPI.methods + WebKitSPI.callbacks
        for entry in all {
            #expect(!entry.use.isEmpty, "\(entry.name) has no use")
            #expect(!entry.fallback.isEmpty, "\(entry.name) has no fallback")
        }
        let keys = all.map { "\($0.owner) \($0.name)" }
        #expect(Set(keys).count == keys.count, "an entry is listed twice")
    }

    /// The checks themselves say no to a name WebKit does not have, so a passing presence test means something.
    @Test func absentNamesAreReportedAbsent() {
        let missingMethod = WebKitSPI.Entry(
            name: "_bowNoSuchMethod:", kind: .method, owner: WebKitSPI.Owner.webView.rawValue, use: "x",
            fallback: "x")
        #expect(!WebKitSPI.isPresent(missingMethod))
        let missingCallback = WebKitSPI.Entry(
            name: "_webView:bowNoSuchCallback:", kind: .callback, owner: "WKUIDelegatePrivate", use: "x",
            fallback: "x")
        #expect(!WebKitSPI.isPresent(missingCallback))
        let missingProtocol = WebKitSPI.Entry(
            name: "_webView:didCountMatches:forString:", kind: .callback, owner: "BowNoSuchProtocol", use: "x",
            fallback: "x")
        #expect(!WebKitSPI.isPresent(missingProtocol))
        #expect(WebKitSPI.symbol("BowNoSuchSymbol") == nil)
    }

    /// The delegate base answers only the private callbacks chosen at init, so a callback nobody handles never
    /// replaces WebKit's public one.
    @Test func delegateBaseAnswersOnlyChosenCallbacks() {
        let base = SPIDelegateBase(privateCallbacks: [.mouseDidMoveOverElement])
        #expect(base.responds(to: WebKitSPI.Callback.mouseDidMoveOverElement.selector))
        #expect(!base.responds(to: WebKitSPI.Callback.processTerminated.selector))
        #expect(!base.responds(to: WebKitSPI.Callback.beforeUnloadPanel.selector))
        #expect(base.responds(to: #selector(NSObject.isEqual(_:))))
    }
}
