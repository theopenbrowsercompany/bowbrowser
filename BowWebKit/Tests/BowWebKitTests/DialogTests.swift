import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab delegate that holds each page dialog until the test answers it, recording what the page asked.
@MainActor
final class DialogRecordingDelegate: EngineTabDelegate {
    private(set) var dialogs: [PageDialog] = []
    private var waiting: [CheckedContinuation<PageDialogAnswer, Never>] = []

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {}

    func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer {
        dialogs.append(dialog)
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Waits for the `count`th dialog to arrive and returns it.
    func waitForDialog(_ count: Int) async throws -> PageDialog {
        try await waitFor("dialog \(count); saw \(dialogs.count)", timeout: 10) {
            dialogs.count >= count && waiting.count == 1 ? dialogs[count - 1] : nil
        }
    }

    /// Answers the dialog that is waiting.
    func answer(_ answer: PageDialogAnswer) {
        waiting.removeFirst().resume(returning: answer)
    }
}

/// A page's alert, confirm and prompt reach the delegate's `runDialog` with what the page asked, and the page gets
/// the answer; a dialog open when its tab closes is answered once, as cancelled, and lets the page go.
@Suite(.serialized) @MainActor struct DialogTests {
    init() {
        TestHost.start()
    }

    /// Clicks the page's own button `id` (its handler asks for the dialog) from the test world without waiting, since
    /// the click returns only once the dialog is answered.
    private func press(_ id: String, in driver: PageDriver) -> Task<Void, any Error> {
        Task { @MainActor in
            _ = try await driver.eval("document.getElementById(id).click(); return true", ["id": id])
        }
    }

    /// The JSON the page wrote for its last dialog's return value.
    private func pageAnswer(_ driver: PageDriver) async throws -> String {
        try await driver.string("return document.getElementById('answer').textContent")
    }

    @Test func alertConfirmAndPromptReachRunDialogAndThePageGetsTheAnswer() async throws {
        let rig = try TabRig()
        let page = rig.url("/dialogs/index.html")
        let tab = rig.tab("/dialogs/index.html")
        let delegate = DialogRecordingDelegate()
        tab.delegate = delegate
        // The driver holds the web view, so it lives only in this block, before the tab's page is checked released.
        do {
            let driver = PageDriver(tab.webView!)
            try await driver.waitForLoad(of: page)
            let origin = URL(string: rig.server.base)!

            var click = press("alert", in: driver)
            let alert = try await delegate.waitForDialog(1)
            #expect(alert == PageDialog(kind: .alert, origin: origin, message: "Saved"))
            #expect(alert.title == "127.0.0.1:\(rig.server.port) says")
            delegate.answer(.ok)
            try await click.value
            #expect(try await pageAnswer(driver) == "\"returned\"")

            click = press("confirm", in: driver)
            #expect(
                try await delegate.waitForDialog(2) == PageDialog(kind: .confirm, origin: origin, message: "Leave?"))
            delegate.answer(.cancelled)
            try await click.value
            #expect(try await pageAnswer(driver) == "false", "a declined confirm returns false")

            click = press("confirm", in: driver)
            _ = try await delegate.waitForDialog(3)
            delegate.answer(.ok)
            try await click.value
            #expect(try await pageAnswer(driver) == "true")

            click = press("prompt", in: driver)
            #expect(
                try await delegate.waitForDialog(4)
                    == PageDialog(kind: .prompt, origin: origin, message: "Your name?", defaultPromptText: "Ada"))
            delegate.answer(PageDialogAnswer(accepted: true, text: "Grace"))
            try await click.value
            #expect(try await pageAnswer(driver) == "\"Grace\"", "prompt returns the typed text")

            click = press("prompt", in: driver)
            _ = try await delegate.waitForDialog(5)
            delegate.answer(.cancelled)
            try await click.value
            #expect(try await pageAnswer(driver) == "null", "a cancelled prompt returns null")

            // A prompt with no default text starts empty, and OK with no text gives the page an empty string.
            click = press("prompt-empty", in: driver)
            #expect(try await delegate.waitForDialog(6).defaultPromptText == "")
            delegate.answer(.ok)
            try await click.value
            #expect(try await pageAnswer(driver) == "\"\"")
            #expect(tab.webView?.openDialogs.isEmpty == true)
        }
        try await rig.finish()
    }

    @Test func aDialogWithNoDelegateIsCancelled() async throws {
        let rig = try TabRig()
        let page = rig.url("/dialogs/index.html")
        let tab = rig.tab("/dialogs/index.html")
        do {
            let driver = PageDriver(tab.webView!)
            try await driver.waitForLoad(of: page)
            tab.delegate = nil
            try await press("confirm", in: driver).value
            #expect(try await pageAnswer(driver) == "false")
        }
        try await rig.finish()
    }

    /// Closing the tab while its confirm is open answers the page once, as cancelled, before the web view goes, and
    /// the delegate's late answer does nothing.
    @Test func aDialogOpenWhenTheTabClosesIsAnsweredOnce() async throws {
        let rig = try TabRig()
        let page = rig.url("/dialogs/index.html")
        let tab = rig.tab("/dialogs/index.html")
        let delegate = DialogRecordingDelegate()
        tab.delegate = delegate
        var driver: PageDriver? = PageDriver(tab.webView!)
        try await driver!.waitForLoad(of: page)
        let click = press("confirm", in: driver!)
        driver = nil
        _ = try await delegate.waitForDialog(1)
        weak let released = tab.webView
        #expect(released?.openDialogs.count == 1)
        #expect(await tab.close())
        // Asked before the web view can go: the close answered the open dialog.
        #expect(released == nil || released?.openDialogs.isEmpty == true, "the open dialog was not answered")
        // The page's script ends without a value once the web view is gone; either way the click returns.
        _ = try? await click.value
        delegate.answer(.ok)
        try await rig.finish()
        try await waitUntil("the web view is released", timeout: 5) { released == nil }
    }
}
