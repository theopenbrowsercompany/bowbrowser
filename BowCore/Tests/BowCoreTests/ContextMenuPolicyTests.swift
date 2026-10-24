import BowCore
import BowCoreTestSupport
import Foundation
import Testing

// The menu variants the e2e check does not reach (it right clicks a link): editable fields, images, a bare page, and
// the mock's inspector and context menu plumbing.
@Suite @MainActor struct ContextMenuPolicyTests {
    let link = URL(string: "https://example.com/a")!
    let image = URL(string: "https://example.com/i.png")!

    func request(
        link: URL? = nil, image: URL? = nil, selection: String = "", editable: Bool = false,
        flags: ContextMenuEditFlags = [], back: Bool = false
    ) -> ContextMenuRequest {
        ContextMenuRequest(
            profileID: .default, position: PagePoint(x: 10, y: 20), linkURL: link, imageURL: image,
            selectionText: selection, isEditable: editable, editFlags: flags, canGoBack: back)
    }

    func titles(_ items: [ContextMenuItem]) -> [String] {
        items.map { $0.isSeparator ? "-" : $0.title }
    }

    @Test func barePageShowsNavigationAndInspect() {
        let items = ContextMenuPolicy.items(for: request(back: true))
        #expect(titles(items) == ["Back", "Forward", "Reload", "-", "Inspect"])
        #expect(items[0].isEnabled && !items[1].isEnabled)
    }

    @Test func imageLinkShowsLinkThenImageItems() {
        let items = ContextMenuPolicy.items(for: request(link: link, image: image))
        #expect(
            titles(items) == [
                "Open Link in New Tab", "Copy Link Address", "-", "Copy Image", "Copy Image Address", "-", "Inspect",
            ])
    }

    @Test func editableFieldEnablesWhatItsFlagsAllow() {
        let items = ContextMenuPolicy.items(for: request(editable: true, flags: [.canPaste, .canSelectAll]))
        #expect(titles(items) == ["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All", "-", "Inspect"])
        let enabled = items.filter { $0.isEnabled && !$0.isSeparator }.map(\.title)
        #expect(enabled == ["Paste", "Select All", "Inspect"])
    }

    @Test func selectionOffersCopy() {
        #expect(titles(ContextMenuPolicy.items(for: request(selection: "hi"))) == ["Copy", "-", "Inspect"])
    }

    @Test func defaultDecisionShowsBowsItems() {
        let request = request(link: link)
        #expect(ContextMenuPolicy.defaultDecision(for: request) == .show(ContextMenuPolicy.items(for: request)))
    }

    @Test func mockAsksTheDelegateAndTracksTheInspector() {
        let engine = MockEngine()
        let tab = engine.defaultProfile.createTab(url: link) as! MockTab
        #expect(tab.decideContextMenu(request()) == .engineDefault)
        #expect(!tab.chooseContextMenuCommand(.inspect, request: request()))
        tab.showInspector(inspectingAt: PagePoint(x: 1, y: 2))
        #expect(tab.hasInspector)
        tab.markClosed()
        #expect(!tab.hasInspector)
        #expect(tab.calls.last == .showInspector(PagePoint(x: 1, y: 2)))
    }
}
