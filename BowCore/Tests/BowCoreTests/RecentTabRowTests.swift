import Foundation
import Testing

@testable import BowCore

@Suite struct RecentTabRowTests {
    @Test func syncAppendsUnlistedAndDropsClosed() {
        let a = SidebarItemID("a")
        let b = SidebarItemID("b")
        let c = SidebarItemID("c")
        let d = SidebarItemID("d")
        var list = RecencyList<SidebarItemID>()
        list.use(a)
        list.use(b)
        list.use(c)
        list.sync(open: [d, a, c])
        #expect(list.ids == [c, a, d])
    }

    @Test func spaceLabelUsesTheEmojiWhenThereIsOne() {
        var space = SpaceSummary(
            id: SidebarSpaceID("s"), name: "Work", profileID: SidebarProfileID("p"),
            icon: try? SpaceIcon(emoji: "💼"))
        #expect(space.label == "💼 Work")
        space.icon = nil
        #expect(space.label == "Work")
    }
}
