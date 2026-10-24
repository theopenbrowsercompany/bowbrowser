import BowCore
import Foundation
import Testing

// The targets of the WebKit spike's context menu check, from the inputs it observed (the engine's menu items and the
// page script's report), and the merge rules around them. Each resolved request also gives the menu
// `ContextMenuPolicyTests` expects for that kind of target.
@Suite struct ContextMenuTargetTests {
    let page = URL(string: "https://bow.test/menu/")!
    let frame = URL(string: "http://localhost:8123/frame.html")!
    let link = URL(string: "https://bow.test/menu/target")!
    let image = URL(string: "https://bow.test/menu/i.png")!

    func resolve(_ hints: ContextMenuHints, _ reports: [ContextMenuPageReport], back: Bool = false)
        -> ContextMenuRequest
    {
        ContextMenuTargets.request(
            hints: hints, reports: reports, profileID: .default, position: PagePoint(x: 10, y: 20), pageURL: page,
            canGoBack: back, canGoForward: false)
    }

    func main(
        link: URL? = nil, text: String? = nil, image: URL? = nil, selection: String = "", editable: Bool = false
    ) -> ContextMenuPageReport {
        ContextMenuPageReport(
            frameURL: page, isMainFrame: true, linkURL: link, linkText: text, imageURL: image,
            selectionText: selection, isEditable: editable)
    }

    func titles(_ request: ContextMenuRequest) -> [String] {
        ContextMenuPolicy.items(for: request).map { $0.isSeparator ? "-" : $0.title }
    }

    // The spike's five targets.

    @Test func linkTakesTheReportsURLWhenTheMenuOffersLinkItems() {
        let request = resolve(
            ContextMenuHints(offersLinkItems: true), [main(link: link, text: "Target")])
        #expect(request.linkURL == link)
        #expect(request.linkText == "Target")
        #expect(request.frameURL == nil)
        #expect(request.pageURL == page)
        #expect(titles(request) == ["Open Link in New Tab", "Copy Link Address", "-", "Inspect"])
    }

    @Test func imageTakesTheReportsSourceWhenTheMenuOffersImageItems() {
        let request = resolve(ContextMenuHints(offersImageItems: true), [main(image: image)])
        #expect(request.imageURL == image)
        #expect(request.linkURL == nil)
        #expect(titles(request) == ["Copy Image", "Copy Image Address", "-", "Inspect"])
    }

    @Test func textFieldIsEditableWithTheMenusEnabledItems() {
        let hints = ContextMenuHints(
            offeredEditItems: [.canCut, .canCopy, .canPaste], enabledEditItems: [.canPaste])
        let request = resolve(hints, [main(editable: true)])
        #expect(request.isEditable)
        #expect(request.editFlags == [.canPaste])
        let items = ContextMenuPolicy.items(for: request)
        #expect(titles(request) == ["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All", "-", "Inspect"])
        #expect(items.filter { $0.isEnabled && !$0.isSeparator }.map(\.title) == ["Paste", "Inspect"])
    }

    @Test func selectionTakesTheParagraphsTextWhenTheMenuOffersCopy() {
        let paragraph = "A paragraph to select."
        let hints = ContextMenuHints(offeredEditItems: [.canCopy], enabledEditItems: [.canCopy])
        let request = resolve(hints, [main(selection: paragraph)])
        #expect(request.selectionText == paragraph)
        #expect(!request.isEditable)
        #expect(request.editFlags.isEmpty)
        #expect(titles(request) == ["Copy", "-", "Inspect"])
    }

    // Known gap from the spike: a link in a cross origin frame reported the frame's body, and the menu offered only
    // frame items, so the click gets the frame's menu with no link items.
    @Test func crossOriginFrameGetsTheFramesURLAndNoLink() {
        let body = ContextMenuPageReport(frameURL: frame, isMainFrame: false)
        let request = resolve(ContextMenuHints(offersFrameItems: true), [body], back: true)
        #expect(request.frameURL == frame)
        #expect(request.linkURL == nil)
        #expect(titles(request) == ["Back", "Forward", "Reload", "-", "Inspect"])
    }

    // The merge rules.

    @Test func linkItemsWithoutAURLOfferNoLink() {
        let request = resolve(ContextMenuHints(offersLinkItems: true, offersImageItems: true), [main()])
        #expect(request.linkURL == nil)
        #expect(request.linkText == nil)
        #expect(request.imageURL == nil)
        #expect(titles(request) == ["Back", "Forward", "Reload", "-", "Inspect"])
    }

    @Test func aURLWithoutLinkItemsOffersNoLink() {
        let request = resolve(ContextMenuHints(), [main(link: link, text: "Target", image: image)])
        #expect(request.linkURL == nil)
        #expect(request.linkText == nil)
        #expect(request.imageURL == nil)
        #expect(titles(request) == ["Back", "Forward", "Reload", "-", "Inspect"])
    }

    @Test func theLastSubframeReportWinsWhenTheMenuOffersFrameItems() {
        let other = URL(string: "https://bow.test/menu/other")!
        let reports = [
            ContextMenuPageReport(frameURL: page, isMainFrame: false, linkURL: other),
            ContextMenuPageReport(frameURL: frame, isMainFrame: false, linkURL: link),
            main(),
        ]
        let request = resolve(ContextMenuHints(offersLinkItems: true, offersFrameItems: true), reports)
        #expect(request.linkURL == link)
        #expect(request.frameURL == frame)
        #expect(titles(request) == ["Open Link in New Tab", "Copy Link Address", "-", "Inspect"])
    }

    @Test func theMainFrameReportWinsWithoutFrameItems() {
        let reports = [main(link: link), ContextMenuPageReport(frameURL: frame, isMainFrame: false)]
        let request = resolve(ContextMenuHints(offersLinkItems: true), reports)
        #expect(request.linkURL == link)
        #expect(request.frameURL == nil)
    }

    @Test func theLastReportWinsWhenNoneIsFromTheMainFrameOrMatchesFrameItems() {
        let reports = [
            ContextMenuPageReport(frameURL: page, isMainFrame: false),
            ContextMenuPageReport(frameURL: frame, isMainFrame: false, linkURL: link),
        ]
        let request = resolve(ContextMenuHints(offersLinkItems: true), reports)
        #expect(request.linkURL == link)
        #expect(request.frameURL == frame)
    }

    @Test func aStaleMainFrameReportBesideASubframeReportLoses() {
        let reports = [
            ContextMenuPageReport(frameURL: frame, isMainFrame: false, imageURL: image),
            main(selection: "stale", editable: true),
        ]
        let request = resolve(ContextMenuHints(offersImageItems: true, offersFrameItems: true), reports)
        #expect(request.imageURL == image)
        #expect(request.frameURL == frame)
        #expect(!request.isEditable)
        #expect(titles(request) == ["Copy Image", "Copy Image Address", "-", "Inspect"])
    }

    @Test func noReportKeepsOnlyWhatTheMenuSays() {
        let field = resolve(
            ContextMenuHints(
                offersLinkItems: true, offersImageItems: true, offersFrameItems: true,
                offeredEditItems: [.canPaste, .canSelectAll], enabledEditItems: [.canSelectAll]), [])
        #expect(field.linkURL == nil && field.imageURL == nil && field.frameURL == nil)
        #expect(field.isEditable)
        #expect(field.editFlags == [.canSelectAll])
        #expect(titles(field) == ["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All", "-", "Inspect"])

        let bare = resolve(
            ContextMenuHints(offersLinkItems: true, offeredEditItems: [.canCopy], enabledEditItems: [.canCopy]), [],
            back: true)
        #expect(bare.linkURL == nil)
        #expect(bare.selectionText.isEmpty)
        #expect(!bare.isEditable)
        #expect(titles(bare) == ["Back", "Forward", "Reload", "-", "Inspect"])
    }

    @Test func aReportSayingEditableMakesTheTargetEditableWithoutEditingItems() {
        let request = resolve(ContextMenuHints(), [main(selection: "typed", editable: true)])
        #expect(request.isEditable)
        #expect(request.editFlags.isEmpty)
        #expect(request.selectionText.isEmpty)
    }

    @Test func aSelectionInAFieldIsNotShownAsTheSelection() {
        let hints = ContextMenuHints(offeredEditItems: [.canCut, .canCopy], enabledEditItems: [.canCut, .canCopy])
        let request = resolve(hints, [main(selection: "typed")])
        #expect(request.isEditable)
        #expect(request.selectionText.isEmpty)
        #expect(request.editFlags == [.canCut, .canCopy])
    }

    @Test func aSelectionWithoutCopyIsNotShown() {
        let request = resolve(ContextMenuHints(), [main(selection: "text")])
        #expect(request.selectionText.isEmpty)
    }

    @Test func mediaItemsChangeNothingYet() {
        let request = resolve(ContextMenuHints(offersMediaItems: true), [main()], back: true)
        #expect(request == resolve(ContextMenuHints(), [main()], back: true))
    }
}
