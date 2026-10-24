import Foundation
import Testing

@testable import BowCore

@Suite struct FaviconStoreTests {
    /// A byte sequence with the shape of a PNG (signature, IHDR first, IEND last) and `filler` bytes between.
    func png(_ filler: Int = 0, tag: UInt8 = 1) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
        bytes += [UInt8](repeating: tag, count: 17)
        bytes += [UInt8](repeating: tag, count: filler)
        bytes += [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        return Data(bytes)
    }

    func store(
        profile: String = "default", storage: FaviconMemoryStorage = FaviconMemoryStorage(),
        cap: Int = 1_000_000, live: Set<String> = []
    ) -> FaviconStore {
        FaviconStore(profile: profile, storage: storage, capBytes: cap, inUseItemIDs: { live })
    }

    @Test func savedIconReadsBackForItsItem() {
        let icons = store()
        let data = png(10)
        #expect(icons.save(data, itemID: "tab-1"))
        #expect(icons.icon(itemID: "tab-1") == data)
    }

    @Test func unknownItemHasNoIcon() {
        #expect(store().icon(itemID: "tab-1", pageURL: "https://a.test/x") == nil)
    }

    @Test func iconsAreKeptPerProfile() {
        let storage = FaviconMemoryStorage()
        let work = store(profile: "work", storage: storage)
        let home = store(profile: "home", storage: storage)
        work.save(png(5), itemID: "tab-1")
        #expect(home.icon(itemID: "tab-1") == nil)
        #expect(work.icon(itemID: "tab-1") != nil)
    }

    @Test func itemIconBeatsPageAndHost() {
        let icons = store()
        let own = png(1, tag: 1)
        let other = png(2, tag: 2)
        icons.save(other, itemID: "tab-2", pageURL: "https://a.test/x")
        icons.save(own, itemID: "tab-1", pageURL: "https://a.test/y")
        #expect(icons.icon(itemID: "tab-1", pageURL: "https://a.test/x") == own)
    }

    @Test func exactPageBeatsHost() {
        let icons = store()
        let page = png(1, tag: 1)
        let host = png(2, tag: 2)
        icons.save(page, itemID: "tab-1", pageURL: "https://a.test/x")
        icons.save(host, itemID: "tab-2", pageURL: "https://a.test/y")
        #expect(icons.icon(itemID: "tab-3", pageURL: "https://a.test/x") == page)
    }

    @Test func hostIsTheLastFallback() {
        let icons = store()
        let host = png(3)
        icons.save(host, itemID: "tab-1", pageURL: "https://a.test/x")
        #expect(icons.icon(itemID: "tab-9", pageURL: "https://A.test/other") == host)
        #expect(icons.icon(itemID: "tab-9", pageURL: "https://b.test/x") == nil)
        #expect(icons.icon(itemID: "tab-9", pageURL: nil) == nil)
    }

    @Test func pageFragmentIsIgnored() {
        let icons = store()
        let data = png(4)
        icons.save(data, itemID: "tab-1", pageURL: "https://a.test/x#top")
        #expect(icons.icon(itemID: "tab-9", pageURL: "https://a.test/x#other") == data)
    }

    @Test func nonWebAddressesSaveOnlyForTheItem() {
        let icons = store()
        icons.save(png(), itemID: "tab-1", pageURL: "about:blank")
        icons.save(png(), itemID: "tab-2", pageURL: "file:///tmp/a.html")
        #expect(icons.icon(itemID: "tab-1") != nil)
        #expect(icons.icon(itemID: "tab-3", pageURL: "about:blank") == nil)
        #expect(FaviconLookup.sources(itemID: "x", pageURL: "chrome://settings") == [.item("x")])
    }

    @Test func fallbackOrderIsItemPageHostThenNone() {
        #expect(
            FaviconLookup.sources(itemID: "t", pageURL: "https://Example.com/a#f")
                == [.item("t"), .page("https://example.com/a"), .host("example.com")])
        #expect(FaviconLookup.sources(itemID: "t", pageURL: nil) == [.item("t")])
    }

    @Test func hostileItemIDsStayInsideTheFolder() {
        for id in ["../x", "a/b", "..", "a b%", ""] {
            let name = FaviconLookup.fileName(for: .item(id))
            #expect(!name.contains("/"))
            #expect(!name.dropFirst().contains(".."))
            #expect(FaviconLookup.itemID(fromFileName: name) == id)
        }
    }

    @Test func damagedOrMissingFileReadsAsNoIcon() throws {
        let storage = FaviconMemoryStorage()
        let icons = store(storage: storage)
        let good = png(8)
        icons.save(good, itemID: "tab-1", pageURL: "https://a.test/x")
        let own = FaviconLookup.fileName(for: .item("tab-1"))

        try storage.write(profile: "default", name: own, data: Data(good.prefix(20)))
        // The damaged own file is skipped and the page's copy answers.
        #expect(icons.icon(itemID: "tab-1", pageURL: "https://a.test/x") == good)
        #expect(icons.icon(itemID: "tab-1") == nil)

        try storage.write(profile: "default", name: own, data: Data())
        #expect(icons.icon(itemID: "tab-1") == nil)
        try storage.write(profile: "default", name: own, data: Data("not a png at all, just text".utf8))
        #expect(icons.icon(itemID: "tab-1") == nil)
        storage.remove(profile: "default", name: own)
        #expect(icons.icon(itemID: "tab-1") == nil)
    }

    @Test func refusesDataThatIsNotAWholePNGAndSavesNothing() {
        let storage = FaviconMemoryStorage()
        let icons = store(storage: storage)
        #expect(!icons.save(Data(), itemID: "a", pageURL: "https://a.test"))
        #expect(!icons.save(Data("GIF89a....".utf8), itemID: "a", pageURL: "https://a.test"))
        #expect(!icons.save(Data(png(5).dropLast()), itemID: "a", pageURL: "https://a.test"))
        #expect(storage.list(profile: "default").isEmpty)
    }

    @Test func refusesAnIconOverTheSizeLimit() {
        let icons = FaviconStore(profile: "p", storage: FaviconMemoryStorage(), maxIconBytes: 100)
        #expect(!icons.save(png(200), itemID: "a"))
        #expect(icons.save(png(10), itemID: "a"))
    }

    @Test func overTheCapEvictsIconsNoItemUsesOldestFirst() {
        let storage = FaviconMemoryStorage()
        let size = png(100).count
        // Room for three icons.
        let live: Set<String> = ["keep"]
        let icons = store(storage: storage, cap: size * 3 + 5, live: live)
        icons.save(png(100), itemID: "gone-1")
        icons.save(png(100), itemID: "keep")
        icons.save(png(100), itemID: "gone-2")
        #expect(icons.totalBytes == size * 3)
        icons.save(png(100), itemID: "new")
        #expect(icons.icon(itemID: "gone-1") == nil)
        #expect(icons.icon(itemID: "keep") != nil)
        #expect(icons.icon(itemID: "gone-2") != nil)
        #expect(icons.icon(itemID: "new") != nil)
        #expect(icons.totalBytes <= size * 3 + 5)
    }

    @Test func pageAndHostIconsGoBeforeIconsItemsStillUse() {
        let storage = FaviconMemoryStorage()
        let size = png(100).count
        let live: Set<String> = ["a", "b"]
        let icons = store(storage: storage, cap: size * 2 + 5, live: live)
        icons.save(png(100), itemID: "a", pageURL: "https://a.test/x")  // item, page, host: three files
        icons.save(png(100), itemID: "b")
        // Over the cap: the page and host copies are evicted, both items keep theirs.
        #expect(icons.icon(itemID: "a") != nil)
        #expect(icons.icon(itemID: "b") != nil)
        #expect(icons.icon(itemID: "z", pageURL: "https://a.test/x") == nil)
        #expect(icons.totalBytes <= size * 2 + 5)
    }

    @Test func iconsInUseAreNeverEvictedEvenOverTheCap() {
        let live: Set<String> = ["a", "b", "c"]
        let icons = store(cap: 10, live: live)
        for id in live.sorted() { icons.save(png(50), itemID: id) }
        for id in live { #expect(icons.icon(itemID: id) != nil) }
    }

    @Test func theIconJustSavedSurvivesTheCapEvenWhenNoItemIsListedInUse() {
        let icons = store(cap: 10)
        #expect(icons.save(png(50), itemID: "new"))
        #expect(icons.icon(itemID: "new") != nil)
    }

    @Test func removeDropsOnlyTheItemsOwnIcon() {
        let icons = store()
        icons.save(png(7), itemID: "a", pageURL: "https://a.test/x")
        icons.remove(itemID: "a")
        #expect(icons.icon(itemID: "a") == nil)
        #expect(icons.icon(itemID: "a", pageURL: "https://a.test/x") != nil)
    }

    @Test func folderStorageRoundTripsEvictsAndSurvivesDamage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("favicons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FaviconFolderStorage(root: root)
        let size = png(100).count
        let icons = FaviconStore(
            profile: "default", storage: storage, capBytes: size * 2 + 5, inUseItemIDs: { ["a", "b"] })
        let first = png(100)
        icons.save(first, itemID: "a", pageURL: "https://a.test/x")
        #expect(icons.icon(itemID: "a") == first)
        icons.save(png(100), itemID: "b")
        #expect(icons.totalBytes <= size * 2 + 5)
        #expect(icons.icon(itemID: "b") != nil)

        let file = root.appendingPathComponent("default").appendingPathComponent(
            FaviconLookup.fileName(for: .item("b")))
        try Data("garbage".utf8).write(to: file)
        #expect(icons.icon(itemID: "b") == nil)
        // A second store over the same folder sees the same files, as after a relaunch.
        let again = FaviconStore(profile: "default", storage: FaviconFolderStorage(root: root))
        #expect(again.icon(itemID: "b") == nil)
        #expect(icons.totalBytes == again.totalBytes)
    }
}
