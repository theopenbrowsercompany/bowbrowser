import Foundation
import Testing

@testable import BowCore

@Suite struct SpaceAppearanceTests {
    private func makeStore(in folder: URL) throws -> (
        store: SidebarStore, work: SidebarSpaceID, personal: SidebarSpaceID
    ) {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let work = store.graph.spaces[0].id
        try store.renameSpace(work, to: "work")
        let personal = try store.createSpace(title: "personal", activate: false)
        return (store, work, personal)
    }

    // MARK: Validation

    @Test(arguments: [
        "💼", "🏠", "❤️", "🇳🇱", "👍🏽", "👨‍👩‍👧", "1️⃣", " 🎯 \n", "©\u{FE0F}", "#\u{FE0F}\u{20E3}",
        "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
    ])
    func oneEmojiIsAccepted(text: String) throws {
        let icon = try SpaceIcon(emoji: text)
        #expect(icon.kind == .emoji)
        #expect(icon.value == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(arguments: [
        "", "  ", "a", "1", "#", "©", "💼💼", "💼a", "🏠 🏠", "work", "1\u{FE0F}", "#\u{FE0F}", "🇺", "🏻", "😀\u{0301}",
        "😀1", "🇳🇱🇳",
    ])
    func anythingButOneEmojiIsRefused(text: String) {
        #expect(throws: SpaceAppearanceError.invalidEmoji(text)) { try SpaceIcon(emoji: text) }
    }

    @Test(arguments: ["heart", "bolt", "person.fill", "square.and.arrow-up", "icon_2", " star "])
    func symbolNamesAreAccepted(name: String) throws {
        let icon = try SpaceIcon(symbol: name)
        #expect(icon.kind == .symbol)
        #expect(icon.value == name.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: [
        "", " ", "Heart", "2fast", "has space", "bolt!", "💼", ".hidden", String(repeating: "a", count: 65),
    ])
    func badSymbolNamesAreRefused(name: String) {
        #expect(throws: SpaceAppearanceError.invalidSymbolName(name)) { try SpaceIcon(symbol: name) }
    }

    @Test func colorsNormalizeToUppercaseSixDigitHex() throws {
        #expect(try SpaceColor(hex: "#3b5bdb").hex == "#3B5BDB")
        #expect(try SpaceColor(hex: "3B5BDB").hex == "#3B5BDB")
        #expect(try SpaceColor(hex: " #3B5BDB\n").hex == "#3B5BDB")
        #expect(try SpaceColor(hex: "#abc").hex == "#AABBCC")
        let blue = try SpaceColor(hex: "#0000FF")
        #expect(blue.red == 0 && blue.green == 0 && blue.blue == 1)
        let color = try SpaceColor(hex: "#3B5BDB")
        #expect(abs(color.red - 59.0 / 255) < 1e-9)
        #expect(abs(color.green - 91.0 / 255) < 1e-9)
        #expect(abs(color.blue - 219.0 / 255) < 1e-9)
    }

    @Test(arguments: ["", "#", "blue", "#12", "#12345", "#1234567", "#3B5BDG", "#3B5BDB80", "##3B5BDB", "#３Ｂ５"])
    func badColorsAreRefused(text: String) {
        #expect(throws: SpaceAppearanceError.invalidColor(text)) { try SpaceColor(hex: text) }
    }

    // MARK: Store operations

    @Test func aNewSpaceHasNoIconAndTheDefaultTheme() throws {
        try withTemporaryFolder { folder in
            let (store, work, _) = try makeStore(in: folder)
            let space = try #require(store.graph.space(work))
            #expect(space.icon == nil)
            #expect(space.theme == nil)
            #expect(space.resolvedTheme == .default)
            #expect(store.graph.activeTheme == .default)
        }
    }

    @Test func iconAndThemeAreSetPerSpaceAndKeepTheRestOfTheSpace() throws {
        try withTemporaryFolder { folder in
            let (store, work, personal) = try makeStore(in: folder)
            try store.apply([
                .insert(.tab(id: "A", url: "https://a.example"), parent: store.graph.firstSpace.pinnedContainerID)
            ])
            let before = try #require(store.graph.space(work))

            try store.setSpaceIcon(work, emoji: "💼")
            try store.setSpaceTheme(work, primaryColorHex: "#3b5bdb")

            let after = try #require(store.graph.space(work))
            #expect(after.icon == (try SpaceIcon(emoji: "💼")))
            #expect(after.theme?.primaryColor.hex == "#3B5BDB")
            #expect(after.title == before.title)
            #expect(after.pinnedContainerID == before.pinnedContainerID)
            #expect(store.graph.tabIDs(in: work) == ["A"])
            let other = try #require(store.graph.space(personal))
            #expect(other.icon == nil)
            #expect(other.theme == nil)
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func aSymbolReplacesAnEmojiAndNilRemovesTheIcon() throws {
        try withTemporaryFolder { folder in
            let (store, work, _) = try makeStore(in: folder)
            try store.setSpaceIcon(work, emoji: "💼")
            try store.setSpaceIcon(work, symbol: "bolt")
            #expect(store.graph.space(work)?.icon == (try SpaceIcon(symbol: "bolt")))
            try store.setSpaceIcon(work, to: nil)
            #expect(store.graph.space(work)?.icon == nil)
        }
    }

    @Test func nilThemeGoesBackToTheDefault() throws {
        try withTemporaryFolder { folder in
            let (store, work, _) = try makeStore(in: folder)
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            try store.setSpaceTheme(work, to: nil)
            #expect(store.graph.space(work)?.theme == nil)
            #expect(store.graph.space(work)?.resolvedTheme == .default)
        }
    }

    @Test func badValuesAreRefusedAndChangeNothing() throws {
        try withTemporaryFolder { folder in
            let (store, work, _) = try makeStore(in: folder)
            try store.setSpaceIcon(work, emoji: "💼")
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            let before = store.graph
            #expect(throws: SpaceAppearanceError.invalidEmoji("ab")) { try store.setSpaceIcon(work, emoji: "ab") }
            #expect(throws: SpaceAppearanceError.invalidSymbolName("Bad Name")) {
                try store.setSpaceIcon(work, symbol: "Bad Name")
            }
            #expect(throws: SpaceAppearanceError.invalidColor("blue")) {
                try store.setSpaceTheme(work, primaryColorHex: "blue")
            }
            #expect(store.graph == before)
        }
    }

    @Test func anUnknownSpaceIsRefused() throws {
        try withTemporaryFolder { folder in
            let (store, _, _) = try makeStore(in: folder)
            let before = store.graph
            #expect(throws: SidebarStoreError.spaceNotFound("nope")) { try store.setSpaceIcon("nope", emoji: "💼") }
            #expect(throws: SidebarStoreError.spaceNotFound("nope")) {
                try store.setSpaceTheme("nope", primaryColorHex: "#3B5BDB")
            }
            #expect(store.graph == before)
        }
    }

    // MARK: Active theme

    @Test func theActiveThemeFollowsTheSpaceOnScreen() throws {
        try withTemporaryFolder { folder in
            let (store, work, personal) = try makeStore(in: folder)
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            try store.setSpaceTheme(personal, primaryColorHex: "#2F9E44")
            #expect(store.graph.activeTheme.primaryColor.hex == "#3B5BDB")
            try store.switchToSpace(personal)
            #expect(store.graph.activeTheme.primaryColor.hex == "#2F9E44")
            try store.setSpaceTheme(personal, to: nil)
            #expect(store.graph.activeTheme == .default)
        }
    }

    @Test func switchingSpacesLeavesThemesAlone() throws {
        try withTemporaryFolder { folder in
            let (store, work, personal) = try makeStore(in: folder)
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            try store.switchToSpace(personal)
            try store.switchToSpace(work)
            #expect(store.graph.space(work)?.theme?.primaryColor.hex == "#3B5BDB")
            #expect(store.graph.space(personal)?.theme == nil)
        }
    }

    // MARK: Saving and opening

    @Test func iconAndThemeSurviveQuittingAndRelaunching() throws {
        try withTemporaryFolder { folder in
            let (store, work, personal) = try makeStore(in: folder)
            try store.setSpaceIcon(work, emoji: "💼")
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            try store.setSpaceIcon(personal, symbol: "heart")

            let reopened = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            #expect(reopened.openReport.repairs.isEmpty)
            #expect(reopened.openReport.migratedFrom == nil)
            #expect(reopened.graph == store.graph)
            #expect(reopened.graph.space(work)?.icon?.value == "💼")
            #expect(reopened.graph.space(work)?.theme?.primaryColor.hex == "#3B5BDB")
            #expect(reopened.graph.space(personal)?.icon == (try SpaceIcon(symbol: "heart")))
            #expect(reopened.graph.space(personal)?.theme == nil)
        }
    }

    @Test func theFileWritesPlainFieldsAndOmitsUnsetOnes() throws {
        try withTemporaryFolder { folder in
            let (store, work, personal) = try makeStore(in: folder)
            try store.setSpaceIcon(work, emoji: "💼")
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Sidebar.json")))
                    as? [String: Any])
            #expect(object["version"] as? Int == SidebarFileFormat.currentVersion)
            let spaces = try #require(object["spaces"] as? [[String: Any]])
            let saved = try #require(spaces.first { $0["id"] as? String == work.rawValue })
            #expect(saved["icon"] as? [String: String] == ["kind": "emoji", "value": "💼"])
            #expect((saved["theme"] as? [String: Any])?["primaryColor"] as? String == "#3B5BDB")
            let plain = try #require(spaces.first { $0["id"] as? String == personal.rawValue })
            #expect(plain["icon"] == nil)
            #expect(plain["theme"] == nil)
        }
    }

    /// Rewrites the saved Spaces with `edit` and opens the file again.
    private func reopen(_ folder: URL, edit: (inout [[String: Any]]) -> Void) throws -> SidebarStore {
        let url = folder.appendingPathComponent("Sidebar.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var spaces = try #require(object["spaces"] as? [[String: Any]])
        edit(&spaces)
        object["spaces"] = spaces
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return try SidebarStore(fileURL: url)
    }

    @Test func aFileFromBeforeIconsAndThemesOpensWithNoIconAndTheDefaultTheme() throws {
        try withTemporaryFolder { folder in
            let (store, work, _) = try makeStore(in: folder)
            try store.setSpaceIcon(work, emoji: "💼")
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            let opened = try reopen(folder) { spaces in
                for index in spaces.indices {
                    spaces[index]["icon"] = nil
                    spaces[index]["theme"] = nil
                }
            }
            #expect(opened.openReport.migratedFrom == nil)
            #expect(opened.openReport.repairs.isEmpty)
            #expect(opened.graph.spaces.map(\.title) == ["work", "personal"])
            #expect(opened.graph.spaces.allSatisfy { $0.icon == nil && $0.theme == nil })
            #expect(opened.graph.activeTheme == .default)
        }
    }

    @Test func unreadableIconsAndThemesCountAsUnsetAndKeepTheSpace() throws {
        try withTemporaryFolder { folder in
            let (store, work, _) = try makeStore(in: folder)
            try store.setSpaceIcon(work, emoji: "💼")
            try store.setSpaceTheme(work, primaryColorHex: "#3B5BDB")
            let opened = try reopen(folder) { spaces in
                spaces[0]["icon"] = ["kind": "sticker", "value": "x"]
                spaces[0]["theme"] = ["primaryColor": "not a color"]
                spaces[1]["icon"] = ["kind": "emoji", "value": "two words"]
                spaces[1]["theme"] = "blue"
            }
            #expect(opened.graph.spaces.map(\.title) == ["work", "personal"])
            #expect(opened.graph.spaces.allSatisfy { $0.icon == nil && $0.theme == nil })
        }
    }

    @Test func aThemeWithExtraFieldsFromALaterBuildStillOpens() throws {
        try withTemporaryFolder { folder in
            let (_, work, _) = try makeStore(in: folder)
            let opened = try reopen(folder) { spaces in
                spaces[0]["theme"] = ["primaryColor": "#3B5BDB", "secondaryColor": "#FFFFFF", "style": "gradient"]
            }
            #expect(opened.graph.space(work)?.theme?.primaryColor.hex == "#3B5BDB")
        }
    }

    // MARK: Command bar

    @Test func theCommandBarSummaryCarriesTheIcon() throws {
        try withTemporaryFolder { folder in
            let (store, work, personal) = try makeStore(in: folder)
            try store.setSpaceIcon(work, emoji: "💼")
            let summary = SpaceSummary(try #require(store.graph.space(work)))
            #expect(summary.icon == (try SpaceIcon(emoji: "💼")))
            #expect(SpaceSummary(try #require(store.graph.space(personal))).icon == nil)
        }
    }
}
