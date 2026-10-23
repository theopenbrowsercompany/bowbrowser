import Foundation
import Testing

@testable import BowCore

@Suite struct NewSpaceTitleTests {
    @Test func aNewSpaceIsNumberedAfterTheSpacesThereAreAndSkipsTakenNames() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            #expect(store.graph.newSpaceTitle == "Space 2")
            let second = try store.createSpace(title: store.graph.newSpaceTitle)
            let third = try store.createSpace(title: store.graph.newSpaceTitle)
            #expect(store.graph.spaces.map(\.title).suffix(2) == ["Space 2", "Space 3"])
            // Deleting "Space 2" leaves two Spaces, but "Space 3" is taken, so the next one is "Space 4".
            try store.deleteSpace(second)
            #expect(store.graph.space(third) != nil)
            #expect(store.graph.newSpaceTitle == "Space 4")
        }
    }
}
