import BowCoreTestSupport
import Foundation
import Testing

@testable import BowCore

@MainActor
@Suite struct SitePermissionsTests {
    private let meet = URL(string: "https://meet.example.com/room/42")!
    private func request(_ kinds: Set<PermissionKind>, _ url: URL? = nil) -> PermissionRequest {
        PermissionRequest(origin: url ?? meet, kinds: kinds)
    }

    @Test func siteIsTheOriginWithoutDefaultPortOrPath() throws {
        #expect(
            PermissionSite(url: URL(string: "HTTPS://Meet.Example.com:443/x?y")!)?.origin == "https://meet.example.com")
        #expect(PermissionSite(url: URL(string: "http://a.test:8080/")!)?.origin == "http://a.test:8080")
        #expect(
            PermissionSite(url: URL(string: "http://a.test")!) != PermissionSite(url: URL(string: "https://a.test")!))
        #expect(PermissionSite(url: URL(string: "about:blank")!) == nil)
        #expect(PermissionSite(url: URL(string: "file:///tmp/a.html")!) == nil)
        #expect(PermissionSite(url: URL(string: "data:text/html,hi")!) == nil)
    }

    @Test func unansweredRequestsAsk() {
        let store = SitePermissionStore(fileURL: nil)
        #expect(store.decision(for: request([.camera])) == nil)
    }

    @Test func allowIsRememberedPerKindAndSite() throws {
        let store = SitePermissionStore(fileURL: nil)
        let stored = try store.record(.allow, for: request([.camera, .microphone]))
        #expect(stored == [.camera: .allow, .microphone: .allow])
        #expect(store.decision(for: request([.camera])) == .allow)
        #expect(store.decision(for: request([.camera, .microphone])) == .allow)
        // Another kind on the same site, and the same kind on another site, still ask.
        #expect(store.decision(for: request([.camera, .geolocation])) == nil)
        #expect(store.decision(for: request([.camera], URL(string: "https://other.example")!)) == nil)
    }

    @Test func denyBlocksAndABlockedKindDeniesTheWholeRequest() throws {
        let store = SitePermissionStore(fileURL: nil)
        try store.record(.allow, for: request([.microphone]))
        try store.record(.deny, for: request([.camera]))
        let site = try #require(request([]).site)
        #expect(store.setting(for: .camera, on: site) == .block)
        #expect(store.decision(for: request([.camera, .microphone])) == .deny)
        #expect(store.decision(for: request([.camera, .geolocation])) == .deny)
    }

    @Test func dismissalAndSitelessRequestsRememberNothing() throws {
        let store = SitePermissionStore(fileURL: nil)
        #expect(try store.record(.dismiss, for: request([.camera])).isEmpty)
        #expect(try store.record(.allow, for: PermissionRequest(origin: nil, kinds: [.camera])).isEmpty)
        #expect(try store.record(.allow, for: request([.camera], URL(string: "about:blank")!)).isEmpty)
        #expect(store.sites.isEmpty)
        #expect(store.decision(for: PermissionRequest(origin: nil, kinds: [.camera])) == nil)
    }

    @Test func screenCaptureStorageAccessAndUnknownKindsAlwaysAsk() throws {
        let store = SitePermissionStore(fileURL: nil)
        let stored = try store.record(.allow, for: request([.screenCapture, .storageAccess, .other, .microphone]))
        #expect(stored == [.microphone: .allow])
        #expect(store.decision(for: request([.screenCapture])) == nil)
        #expect(store.decision(for: request([.storageAccess])) == nil)
        #expect(store.decision(for: request([.screenCapture, .microphone])) == nil)
    }

    @Test func answersSurviveARestartAndResetForgetsASite() throws {
        try withTemporaryFolder { folder in
            let file = folder.appendingPathComponent("Permissions.json")
            let store = SitePermissionStore(fileURL: file)
            try store.record(.allow, for: request([.camera]))
            try store.record(.deny, for: request([.notifications], URL(string: "https://spam.example")!))

            let reopened = SitePermissionStore(fileURL: file)
            #expect(reopened.decision(for: request([.camera])) == .allow)
            #expect(reopened.decision(for: request([.notifications], URL(string: "https://spam.example/x")!)) == .deny)
            #expect(reopened.sites.map(\.origin) == ["https://meet.example.com", "https://spam.example"])

            try reopened.reset(try #require(request([]).site))
            #expect(SitePermissionStore(fileURL: file).decision(for: request([.camera])) == nil)
        }
    }

    @Test func inMemoryStoresWriteNothing() throws {
        try withTemporaryFolder { folder in
            let store = SitePermissionStore(fileURL: nil)
            try store.record(.allow, for: request([.camera]))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    @Test func anUnreadableFileIsMovedAsideAndGrantsNothing() throws {
        try withTemporaryFolder { folder in
            let file = folder.appendingPathComponent("Permissions.json")
            try Data("{ not json".utf8).write(to: file)
            let store = SitePermissionStore(fileURL: file)
            #expect(store.sites.isEmpty)
            #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("unreadable").path))
            try store.record(.allow, for: request([.camera]))
            #expect(SitePermissionStore(fileURL: file).decision(for: request([.camera])) == .allow)
        }
    }

    @Test func unknownKindsAndSitesInTheFileAreSkipped() throws {
        try withTemporaryFolder { folder in
            let file = folder.appendingPathComponent("Permissions.json")
            let json = """
                {"version": 1, "sites": {
                  "https://meet.example.com": {"camera": "allow", "teleport": "allow", "screenCapture": "allow"},
                  "about:blank": {"camera": "allow"}
                }}
                """
            try Data(json.utf8).write(to: file)
            let store = SitePermissionStore(fileURL: file)
            #expect(store.sites.map(\.origin) == ["https://meet.example.com"])
            #expect(store.decision(for: request([.camera])) == .allow)
            #expect(store.decision(for: request([.screenCapture])) == nil)
        }
    }

    @Test func delegatesWithoutAnAnswerDismiss() async {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: meet) as! MockTab
        #expect(await tab.requestPermission(request([.camera])) == .dismiss)
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        #expect(await tab.requestPermission(request([.camera])) == .dismiss)
    }
}
