import Testing

@testable import BowCore

@Suite struct PageZoomTests {
    @Test func zoomInStepsThroughThePresets() {
        var level = PageZoom.actualSize
        var seen: [Int] = []
        while let next = PageZoom.zoomedIn(from: level) {
            level = next
            seen.append(PageZoom.percent(forLevel: level))
        }
        #expect(seen == [110, 125, 150, 175, 200, 250, 300, 400, 500])
    }

    @Test func zoomOutStepsThroughThePresets() {
        var level = PageZoom.actualSize
        var seen: [Int] = []
        while let next = PageZoom.zoomedOut(from: level) {
            level = next
            seen.append(PageZoom.percent(forLevel: level))
        }
        #expect(seen == [90, 80, 75, 67, 50, 33, 25])
    }

    @Test func aLevelBetweenPresetsMovesToTheNextOne() {
        let between = PageZoom.level(forPercent: 120)
        #expect(PageZoom.percent(forLevel: PageZoom.zoomedIn(from: between) ?? 0) == 125)
        #expect(PageZoom.percent(forLevel: PageZoom.zoomedOut(from: between) ?? 0) == 110)
    }

    @Test func actualSizeIsExactlyZero() {
        #expect(PageZoom.zoomedIn(from: PageZoom.level(forPercent: 90)) == 0)
        #expect(PageZoom.zoomedOut(from: PageZoom.level(forPercent: 110)) == 0)
    }
}
