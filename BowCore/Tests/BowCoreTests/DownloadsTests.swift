import Foundation
import Testing

@testable import BowCore

@Suite struct DownloadListTests {
    private let profile: ProfileID = "Default"

    @Test func createdDownloadsGoFirst() {
        var list = DownloadList()
        list.apply(.created(DownloadItem(id: 1, suggestedFileName: "a.pdf")), from: profile)
        list.apply(.created(DownloadItem(id: 2, suggestedFileName: "b.zip")), from: profile)
        #expect(list.entries.map(\.item.id) == [2, 1])
    }

    @Test func updatesReplaceTheSnapshotInPlace() {
        var list = DownloadList()
        list.apply(.created(DownloadItem(id: 1)), from: profile)
        list.apply(.created(DownloadItem(id: 2)), from: profile)
        let changed = list.apply(.updated(DownloadItem(id: 1, receivedBytes: 10, totalBytes: 20)), from: profile)
        #expect(changed)
        #expect(list.entries.map(\.item.id) == [2, 1])
        #expect(list.entries[1].item.fractionComplete == 0.5)
    }

    @Test func anUpdateForAnUnknownDownloadAddsIt() {
        var list = DownloadList()
        list.apply(.updated(DownloadItem(id: 7, state: .paused)), from: profile)
        #expect(list.entries.first?.item.state == .paused)
    }

    @Test func idsAreOnlyUniquePerProfile() {
        var list = DownloadList()
        list.apply(.created(DownloadItem(id: 1)), from: "Default")
        list.apply(.created(DownloadItem(id: 1)), from: "Work")
        #expect(list.entries.count == 2)
        list.apply(.removed(1), from: "Work")
        #expect(list.entries.map(\.profileID) == ["Default"])
    }

    @Test func aFinalStateNeverChangesBack() {
        var list = DownloadList()
        list.apply(.created(DownloadItem(id: 1)), from: profile)
        list.apply(.updated(DownloadItem(id: 1, state: .cancelled, receivedBytes: 5)), from: profile)
        let changed = list.apply(.updated(DownloadItem(id: 1, state: .inProgress, receivedBytes: 9)), from: profile)
        #expect(!changed)
        #expect(list.entries[0].item.state == .cancelled)
        #expect(list.entries[0].item.receivedBytes == 5)
    }

    @Test func aLateUpdateKeepsTheChosenDestination() {
        var list = DownloadList()
        let file = URL(fileURLWithPath: "/tmp/a.pdf")
        list.apply(.created(DownloadItem(id: 1)), from: profile)
        list.apply(.updated(DownloadItem(id: 1, destination: file)), from: profile)
        list.apply(.updated(DownloadItem(id: 1, receivedBytes: 3)), from: profile)
        #expect(list.entries[0].item.destination == file)
    }

    @Test func onlyRunningDownloadsAreActive() {
        var list = DownloadList()
        list.apply(.created(DownloadItem(id: 1, state: .inProgress)), from: profile)
        list.apply(.created(DownloadItem(id: 2, state: .paused)), from: profile)
        list.apply(.created(DownloadItem(id: 3, state: .complete)), from: profile)
        list.apply(.created(DownloadItem(id: 4, state: .interrupted)), from: profile)
        #expect(Set(list.active.map(\.item.id)) == [1, 2])
    }
}

@Suite struct DownloadItemTests {
    @Test func controlsFollowTheState() {
        let running = DownloadItem(id: 1, state: .inProgress)
        #expect(running.canPause && !running.canResume && running.canCancel && !running.canRemove)
        let paused = DownloadItem(id: 1, state: .paused)
        #expect(!paused.canPause && paused.canResume && paused.canCancel && !paused.canRemove)
        let complete = DownloadItem(id: 1, state: .complete)
        #expect(!complete.canPause && !complete.canResume && !complete.canCancel && complete.canRemove)
        let failed = DownloadItem(id: 1, state: .interrupted)
        #expect(failed.canResume && failed.canCancel && failed.canRemove)
    }

    @Test func progressIsUnknownWithoutASize() {
        #expect(DownloadItem(id: 1, receivedBytes: 10).fractionComplete == nil)
        #expect(DownloadItem(id: 1, state: .complete, receivedBytes: 10).fractionComplete == 1)
    }

    @Test func theNameComesFromTheDestinationOnceChosen() {
        var item = DownloadItem(id: 1, suggestedFileName: "a.pdf")
        #expect(item.fileName == "a.pdf")
        item.destination = URL(fileURLWithPath: "/tmp/a (1).pdf")
        #expect(item.fileName == "a (1).pdf")
        #expect(DownloadItem(id: 2).fileName == "download")
    }

    @Test func statusTextNamesTheState() {
        #expect(DownloadItem(id: 1, state: .cancelled).statusText == "Cancelled")
        #expect(DownloadItem(id: 1, state: .paused, receivedBytes: 0).statusText.hasPrefix("Paused, "))
        #expect(DownloadItem(id: 1, state: .complete).statusText.hasPrefix("Complete, "))
    }
}

@Suite struct DownloadDestinationTests {
    private let folder = URL(fileURLWithPath: "/tmp/bow-downloads-test", isDirectory: true)

    @Test func savesIntoTheFolderUnderTheSuggestedName() {
        let destination = DownloadDestination.choose(
            suggestedName: "a.pdf", folder: folder, askWhereToSave: false, isTaken: { _ in false })
        #expect(destination == .save(folder.appendingPathComponent("a.pdf")))
    }

    @Test func asksWithTheSameSuggestionWhenSetToAsk() {
        let destination = DownloadDestination.choose(
            suggestedName: "a.pdf", folder: folder, askWhereToSave: true, isTaken: { $0 == "a.pdf" })
        #expect(destination == .ask(suggested: folder.appendingPathComponent("a (1).pdf")))
    }

    @Test func numbersTakenNames() {
        let taken: Set = ["a.pdf", "a (1).pdf"]
        #expect(DownloadDestination.uniqueFileName("a.pdf", isTaken: taken.contains) == "a (2).pdf")
        #expect(DownloadDestination.uniqueFileName("README", isTaken: { $0 == "README" }) == "README (1)")
        #expect(DownloadDestination.uniqueFileName("x.tar.gz", isTaken: { $0 == "x.tar.gz" }) == "x (1).tar.gz")
    }

    @Test func makesUnsafeNamesSafe() {
        #expect(DownloadDestination.safeFileName("../../etc/passwd") == "_.._etc_passwd")
        #expect(DownloadDestination.safeFileName(".hidden") == "hidden")
        #expect(DownloadDestination.safeFileName("a:b\u{0007}.txt") == "a_b.txt")
        #expect(DownloadDestination.safeFileName("  ") == "download")
    }
}
