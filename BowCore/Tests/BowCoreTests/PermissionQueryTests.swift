import Foundation
import Testing

@testable import BowCore

@MainActor
@Suite struct PermissionQueryTests {
    private let meet = URL(string: "https://meet.example.com/room/42")!
    private func request(_ kinds: Set<PermissionKind>, _ url: URL? = nil) -> PermissionRequest {
        PermissionRequest(origin: url ?? meet, kinds: kinds)
    }

    @Test func grantedDeniedAndPromptFromTheStore() throws {
        let store = SitePermissionStore(fileURL: nil)
        #expect(store.state(of: .camera, on: meet) == .prompt)
        try store.record(.allow, for: request([.camera]))
        #expect(store.state(of: .camera, on: meet) == .granted)
        try store.record(.deny, for: request([.camera]))
        #expect(store.state(of: .camera, on: meet) == .denied)
    }

    @Test func mixedStoreAnswersEachKindApart() throws {
        let store = SitePermissionStore(fileURL: nil)
        try store.record(.allow, for: request([.camera]))
        try store.record(.deny, for: request([.microphone]))
        #expect(store.state(of: .camera, on: meet) == .granted)
        #expect(store.state(of: .microphone, on: meet) == .denied)
        #expect(store.state(of: .geolocation, on: meet) == .prompt)
        #expect(store.state(of: .camera, on: URL(string: "https://other.example.com/")!) == .prompt)
    }

    @Test func pageWithoutAWebOriginPrompts() throws {
        let store = SitePermissionStore(fileURL: nil)
        try store.record(.allow, for: request([.camera]))
        for text in ["file:///tmp/a.html", "about:blank", "data:text/html,hi"] {
            #expect(store.state(of: .camera, on: URL(string: text)!) == .prompt)
        }
        #expect(store.state(of: .camera, on: nil) == .prompt)
    }

    @Test func kindsNeverRememberedPromptEvenAfterAnAnswer() throws {
        let store = SitePermissionStore(fileURL: nil)
        let never = PermissionKind.allCases.filter { !$0.isRemembered }
        #expect(!never.isEmpty)
        for kind in never {
            try store.record(.allow, for: request([kind]))
            #expect(store.state(of: kind, on: meet) == .prompt)
            try store.record(.deny, for: request([kind]))
            #expect(store.state(of: kind, on: meet) == .prompt)
        }
    }

    @Test func oneProfilesAnswerIsNotSeenInAnother() throws {
        let first = SitePermissionStore(fileURL: nil)
        let second = SitePermissionStore(fileURL: nil)
        try first.record(.allow, for: request([.camera]))
        #expect(first.state(of: .camera, on: meet) == .granted)
        #expect(second.state(of: .camera, on: meet) == .prompt)
    }

    @Test func namesMapBothWays() {
        let pairs: [(String, PermissionKind)] = [
            ("camera", .camera), ("microphone", .microphone), ("geolocation", .geolocation),
            ("notifications", .notifications), ("clipboard-read", .clipboard), ("storage-access", .storageAccess),
            ("window-management", .windowManagement), ("local-fonts", .localFonts),
            ("display-capture", .screenCapture),
        ]
        for (name, kind) in pairs {
            #expect(PermissionKind(permissionsAPIName: name) == kind)
            #expect(kind.permissionsAPIName == name)
        }
    }

    @Test func midiIsTheSysexKindOnlyWhenAskedForSysex() {
        #expect(PermissionKind(permissionsAPIName: "midi", sysex: true) == .midiSysex)
        #expect(PermissionKind(permissionsAPIName: "midi", sysex: false) == nil)
        #expect(PermissionKind(permissionsAPIName: "midi") == nil)
        #expect(PermissionKind.midiSysex.permissionsAPIName == "midi")
    }

    @Test func unknownNamesAndUnstoredKindsMapToNothing() {
        for name in ["clipboard-write", "push", "bogus", "", "Camera"] {
            #expect(PermissionKind(permissionsAPIName: name) == nil)
            #expect(PermissionKind(permissionsAPIName: name, sysex: true) == nil)
        }
        #expect(PermissionKind.other.permissionsAPIName == nil)
    }

    @Test func everyKindWithANameRoundTrips() {
        for kind in PermissionKind.allCases {
            guard let name = kind.permissionsAPIName else { continue }
            #expect(PermissionKind(permissionsAPIName: name, sysex: true) == kind)
        }
    }
}
