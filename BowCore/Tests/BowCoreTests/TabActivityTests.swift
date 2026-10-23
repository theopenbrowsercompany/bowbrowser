import Foundation
import Testing

@testable import BowCore

@Suite struct TabActivityTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "bow-activity-\(UUID().uuidString)", isDirectory: true)
    var file: URL { TabActivity.fileURL(inApplicationSupportFolder: folder) }

    @Test func recordKeepsTheLatestTime() {
        let clock = ManualTimeSource()
        let activity = TabActivity(fileURL: file, clock: clock)
        activity.record("a")
        clock.advance(by: 5)
        activity.record("b")
        clock.advance(by: 5)
        activity.record("a")
        #expect(activity.lastActive("a") == clock.now)
        #expect(activity.lastActive("b") == clock.now.addingTimeInterval(-5))
        #expect(activity.lastActive("c") == nil)
    }

    @Test func roundTripsThroughTheFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ManualTimeSource()
        let activity = TabActivity(fileURL: file, clock: clock)
        activity.record("a")
        try activity.save()
        #expect(!activity.hasUnsavedChanges)
        let reopened = TabActivity(fileURL: file, clock: clock)
        #expect(reopened.openReport == .loaded)
        #expect(reopened.lastActive == activity.lastActive)
    }

    @Test func missingFileStartsEmpty() {
        let activity = TabActivity(fileURL: file)
        #expect(activity.openReport == .freshBecauseMissing)
        #expect(activity.lastActive.isEmpty)
    }

    @Test func corruptFileIsKeptAsideAndStartsEmpty() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let activity = TabActivity(fileURL: file)
        guard case .freshAfterSettingAside(let aside?, _) = activity.openReport else {
            Issue.record("expected the bad file to be set aside, got \(activity.openReport)")
            return
        }
        #expect(try Data(contentsOf: aside) == Data("not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(activity.lastActive.isEmpty)
    }

    @Test func pruneDropsUnknownItems() {
        let activity = TabActivity(fileURL: file)
        activity.record("a")
        activity.record("b")
        activity.prune(keeping: ["a", "z"])
        #expect(Set(activity.lastActive.keys) == ["a"])
    }

    @Test func clockIsInjected() {
        let moment = Date(timeIntervalSince1970: 42)
        let activity = TabActivity(fileURL: file, clock: ManualTimeSource(moment))
        activity.record("a")
        #expect(activity.lastActive("a") == moment)
    }
}
