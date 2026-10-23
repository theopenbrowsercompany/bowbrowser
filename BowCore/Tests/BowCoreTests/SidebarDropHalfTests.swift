import Testing

@testable import BowCore

@Suite struct SidebarDropHalfTests {
    @Test func upperAndLowerHalves() {
        #expect(!SidebarDropHalf.isLower(offset: 0, height: 28))
        #expect(!SidebarDropHalf.isLower(offset: 7, height: 28))
        #expect(!SidebarDropHalf.isLower(offset: 14, height: 28))
        #expect(SidebarDropHalf.isLower(offset: 21, height: 28))
        #expect(SidebarDropHalf.isLower(offset: 28, height: 28))
    }

    @Test func unusableInputIsUpper() {
        #expect(!SidebarDropHalf.isLower(offset: 5, height: 0))
        #expect(!SidebarDropHalf.isLower(offset: .nan, height: 28))
        #expect(!SidebarDropHalf.isLower(offset: 20, height: .infinity))
    }
}
