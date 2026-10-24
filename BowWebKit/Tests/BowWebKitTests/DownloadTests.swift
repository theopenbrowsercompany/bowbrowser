import BowCore
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import BowWebKit

/// A tab rig with downloads: a delegate that saves every download in a folder of its own under the temporary folder
/// (never ~/Downloads), and two download routes on the local fixture server, `/fast.bin` sent at once and
/// `/slow.bin` sent 16 KiB every 50 ms, both attachments of the same 1 MiB that answer `Range` requests, so a paused
/// download can resume. `finish()` cancels what is still running, closes the tabs and removes the folder.
@MainActor
final class DownloadRig {
    let tabs: TabRig
    let folder: URL
    let delegate: RecordingDownloadsDelegate
    var downloads: WebKitDownloads { tabs.profile.webKitDownloads }

    /// The file both routes send: bytes from a fixed pseudo random sequence, so a resume from a wrong offset shows.
    nonisolated static let body: Data = {
        var state: UInt32 = 0x2545_F491
        return Data(
            (0..<(1 << 20)).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 24)
            })
    }()

    init() throws {
        tabs = try TabRig()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bowwebkit-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        delegate = RecordingDownloadsDelegate(folder: folder)
        tabs.profile.webKitDownloads.delegate = delegate
        tabs.server.route("/fast.bin") { Self.answer($0, name: "fast.bin", pace: nil) }
        tabs.server.route("/slow.bin") {
            Self.answer($0, name: "slow.bin", pace: .init(bytes: 16 * 1024, interval: 0.05))
        }
        tabs.server.route("/link.html") { _ in
            .html("<!doctype html><title>link</title><a id=get href=\"/fast.bin\" download>get</a>")
        }
    }

    /// The download route's answer: the whole body, or from the byte a `Range: bytes=<n>-` asks for.
    nonisolated static func answer(
        _ request: FixtureServer.Request, name: String, pace: FixtureServer.Response.Pace?
    ) -> FixtureServer.Response {
        var headers = [
            "Content-Type: application/octet-stream", "Content-Disposition: attachment; filename=\"\(name)\"",
            "ETag: \"bow-download-1\"", "Last-Modified: Wed, 21 Oct 2026 07:28:00 GMT", "Accept-Ranges: bytes",
        ]
        let body = Self.body
        if let range = request.headers["range"], range.hasPrefix("bytes="),
            let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? ""), start < body.count
        {
            headers.append("Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)")
            return .init(status: 206, headers: headers, body: body.subdata(in: start..<body.count), pace: pace)
        }
        return .init(status: 200, headers: headers, body: body, pace: pace)
    }

    /// The listed download, if any (each test starts one).
    var item: DownloadItem? { downloads.items.first }

    /// Waits until the listed download satisfies `condition`, and returns it.
    func waitForItem(
        _ what: String, timeout: Double = 30, _ condition: @escaping (DownloadItem) -> Bool
    ) async throws -> DownloadItem {
        try await waitFor("\(what); saw \(String(describing: item))", timeout: timeout) {
            item.flatMap { condition($0) ? $0 : nil }
        }
    }

    /// Waits until the slow download receives bytes into its chosen file, past its first pieces, with the progress
    /// pushed to the delegate as it goes.
    func waitForSlowRunning() async throws -> DownloadItem {
        let past = Int64(64 * 1024)
        return try await waitForItem("slow.bin receiving bytes into its file, pushed past \(past) bytes") { item in
            item.state == .inProgress && item.destination == self.folder.appendingPathComponent("slow.bin")
                && item.receivedBytes >= past && item.receivedBytes < Int64(Self.body.count)
                && self.delegate.events.contains {
                    if case .updated(let pushed) = $0 { pushed.receivedBytes >= past } else { false }
                }
        }
    }

    /// The SHA-256 of the file at `url`, or nil when there is none.
    static func digest(_ url: URL?) -> SHA256Digest? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data)
    }

    static let bodyDigest = SHA256.hash(data: body)

    func fileExists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    var folderContents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    func finish() async throws {
        downloads.cancelAll()
        try await tabs.finish()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A downloads delegate that saves each download as its suggested name in `folder`, records every event, and allows
/// downloads while `allows` is true.
@MainActor
final class RecordingDownloadsDelegate: EngineDownloadsDelegate {
    let folder: URL
    var allows = true
    private(set) var events: [DownloadEvent] = []
    /// The suggested names the engine asked a destination for, in order.
    private(set) var asked: [String] = []

    init(folder: URL) {
        self.folder = folder
    }

    func downloads(_ downloads: any EngineDownloads, didReceive event: DownloadEvent) {
        events.append(event)
    }

    func downloads(
        _ downloads: any EngineDownloads, destinationFor item: DownloadItem, suggestedName: String
    ) async -> URL? {
        asked.append(suggestedName)
        return folder.appendingPathComponent(suggestedName)
    }

    func downloads(_ downloads: any EngineDownloads, shouldAllowDownloadFrom url: URL) -> Bool { allows }
}

/// Downloads on WebKit: an attachment downloads into the folder the app chose; pause and resume keep the bytes;
/// cancel deletes the file; remove forgets the entry; a refused download leaves nothing; quitting cancels; and a
/// download completes after the tab that started it closed and its web view was released (the W1 side question).
@Suite(.serialized) @MainActor struct DownloadTests {
    init() {
        TestHost.start()
    }

    private func withRig(_ body: (DownloadRig) async throws -> Void) async throws {
        let rig = try DownloadRig()
        var failure: (any Error)?
        do { try await body(rig) } catch { failure = error }
        do { try await rig.finish() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    @Test func anAttachmentDownloadsIntoTheChosenFolderWithTheServersBytes() async throws {
        try await withRig { rig in
            let url = rig.tabs.url("/fast.bin")
            let tab = rig.tabs.tab("/fast.bin")
            let done = try await rig.waitForItem("fast.bin complete with all its bytes in the folder") {
                $0.state == .complete && $0.receivedBytes == Int64(DownloadRig.body.count)
                    && rig.fileExists($0.destination)
            }
            #expect(done.url == url && done.suggestedFileName == "fast.bin" && done.totalBytes == done.receivedBytes)
            #expect(done.destination == rig.folder.appendingPathComponent("fast.bin"))
            #expect(DownloadRig.digest(done.destination) == DownloadRig.bodyDigest)
            #expect(rig.delegate.asked == ["fast.bin"])
            #expect(rig.delegate.events.first.map { if case .created = $0 { true } else { false } } == true)
            // The download ended the tab's navigation as aborted, and the tab is still open.
            let failed = try await rig.tabs.delegate.wait(for: "the download's navigation failing") {
                if case .didFail(let navigation, _) = $0 { navigation.url == url } else { false }
            }
            if case .didFail(_, let error) = failed { #expect(error.reason == .aborted) }
            #expect(!tab.isClosed && rig.tabs.delegate.navigation.allSatisfy { !$0.hasPrefix("commit \(url)") })
        }
    }

    @Test func aDownloadLinkDownloadsWithoutNavigatingOrAskingTheAppsPolicy() async throws {
        try await withRig { rig in
            let page = rig.tabs.url("/link.html")
            let tab = rig.tabs.tab("/link.html")
            try await rig.tabs.waitFor("finish \(page.absoluteString)")
            rig.tabs.delegate.reset()
            _ = try await tab.webView?.callAsyncJavaScript(
                "document.getElementById('get').click()", arguments: [:], in: nil, contentWorld: .defaultClient)
            let done = try await rig.waitForItem("the linked fast.bin complete in the folder") {
                $0.state == .complete && rig.fileExists($0.destination)
            }
            #expect(DownloadRig.digest(done.destination) == DownloadRig.bodyDigest)
            #expect(rig.tabs.delegate.policyRequests.isEmpty)
            #expect(rig.tabs.delegate.navigation.isEmpty && tab.state.url == page)
        }
    }

    @Test func pauseThenResumeFinishesWithTheSameBytes() async throws {
        try await withRig { rig in
            _ = rig.tabs.tab("/slow.bin")
            let running = try await rig.waitForSlowRunning()
            rig.downloads.pause(running.id)
            let paused = try await rig.waitForItem("slow.bin paused partway") {
                $0.state == .paused && $0.receivedBytes > 0 && $0.receivedBytes < Int64(DownloadRig.body.count)
            }
            let requestsBefore = rig.tabs.server.log().filter { $0.path == "/slow.bin" }.count

            let pausedEvents = rig.delegate.events.count
            rig.downloads.resume(paused.id)
            try await waitUntil("progress pushed past \(paused.receivedBytes) bytes after resuming") {
                rig.delegate.events.dropFirst(pausedEvents).contains {
                    if case .updated(let item) = $0 {
                        item.state == .inProgress && item.receivedBytes > paused.receivedBytes
                    } else {
                        false
                    }
                }
            }
            let done = try await rig.waitForItem("slow.bin complete after resuming", timeout: 60) {
                $0.state == .complete && rig.fileExists($0.destination)
            }
            #expect(done.receivedBytes == Int64(DownloadRig.body.count))
            #expect(DownloadRig.digest(done.destination) == DownloadRig.bodyDigest)
            // It resumed where it stopped, through a range request, rather than starting again.
            let resumes = rig.tabs.server.log().filter { $0.path == "/slow.bin" }.dropFirst(requestsBefore)
            #expect(
                resumes.contains {
                    ($0.headers["range"] ?? "").hasPrefix("bytes=") && $0.headers["range"] != "bytes=0-"
                })
            #expect(rig.delegate.asked == ["slow.bin"])
        }
    }

    @Test func cancelLeavesNoFileAndRemoveForgetsTheEntry() async throws {
        try await withRig { rig in
            _ = rig.tabs.tab("/slow.bin")
            let running = try await rig.waitForSlowRunning()
            // A running download cannot leave the list.
            rig.downloads.remove(running.id)
            #expect(rig.downloads.items.map(\.id) == [running.id])

            rig.downloads.cancel(running.id)
            let cancelled = try await rig.waitForItem("slow.bin cancelled with no file left") {
                $0.state == .cancelled && !rig.fileExists($0.destination) && rig.folderContents.isEmpty
            }
            #expect(cancelled.id == running.id)

            rig.downloads.remove(running.id)
            #expect(rig.downloads.items.isEmpty)
            #expect(rig.delegate.events.last == .removed(running.id))
            #expect(rig.folderContents.isEmpty)
        }
    }

    /// The W1 side question: does a `WKDownload` finish after its web view is released? It does, because the
    /// profile's downloads, not the tab, hold it and are its delegate.
    @Test func aDownloadCompletesAfterItsTabClosedAndItsWebViewWasReleased() async throws {
        try await withRig { rig in
            let tab = rig.tabs.tab("/slow.bin", shown: false)
            _ = try await rig.waitForSlowRunning()
            let page = WeakBox(try #require(tab.webView))
            #expect(await tab.close())
            try await waitUntil("the closed tab's web view released; saw \(String(describing: page.object))") {
                page.object == nil
            }
            let released = try #require(rig.item)
            #expect(released.state == .inProgress)
            try await waitUntil("progress pushed past \(released.receivedBytes) bytes with the web view gone") {
                rig.delegate.events.contains {
                    if case .updated(let item) = $0 {
                        item.state == .inProgress && item.receivedBytes > released.receivedBytes
                    } else {
                        false
                    }
                }
            }

            let done = try await rig.waitForItem("slow.bin complete with its web view gone", timeout: 60) {
                $0.state == .complete && rig.fileExists($0.destination)
            }
            #expect(done.receivedBytes == Int64(DownloadRig.body.count))
            #expect(DownloadRig.digest(done.destination) == DownloadRig.bodyDigest)
        }
    }

    @Test func aRefusedDownloadSendsNoEventAndSavesNothing() async throws {
        try await withRig { rig in
            let url = rig.tabs.url("/fast.bin")
            // The delegate says no.
            rig.delegate.allows = false
            _ = rig.tabs.tab("/fast.bin")
            _ = try await rig.tabs.delegate.wait(for: "the refused download's navigation failing") {
                if case .didFail(let navigation, _) = $0 { navigation.url == url } else { false }
            }
            #expect(rig.downloads.items.isEmpty && rig.delegate.events.isEmpty && rig.folderContents.isEmpty)

            // No delegate at all.
            rig.tabs.delegate.reset()
            rig.downloads.delegate = nil
            _ = rig.tabs.tab("/fast.bin")
            _ = try await rig.tabs.delegate.wait(for: "the undelegated download's navigation failing") {
                if case .didFail(let navigation, _) = $0 { navigation.url == url } else { false }
            }
            #expect(rig.downloads.items.isEmpty && rig.delegate.events.isEmpty && rig.folderContents.isEmpty)
        }
    }

    @Test func quittingCancelsARunningDownloadAndRefusesNewOnes() async throws {
        try await withRig { rig in
            _ = rig.tabs.tab("/slow.bin")
            let running = try await rig.waitForSlowRunning()
            rig.tabs.profile.beginQuit()
            let cancelled = try await rig.waitForItem("slow.bin cancelled by the quit with no file left") {
                $0.state == .cancelled && !rig.fileExists($0.destination) && rig.folderContents.isEmpty
            }
            #expect(cancelled.id == running.id)
            #expect(!rig.downloads.accepts(rig.tabs.url("/fast.bin")))
        }
    }
}
