import Testing

@testable import BowCore

@Suite struct PageZoomTests {
    @Test func zoomInStepsThroughThePresets() {
        var factor = PageZoom.actualSize
        var seen: [Int] = []
        while let next = PageZoom.zoomedIn(from: factor) {
            factor = next
            seen.append(PageZoom.percent(forFactor: factor))
        }
        #expect(seen == [110, 125, 150, 175, 200, 250, 300, 400, 500])
        #expect(factor == 5)
    }

    @Test func zoomOutStepsThroughThePresets() {
        var factor = PageZoom.actualSize
        var seen: [Int] = []
        while let next = PageZoom.zoomedOut(from: factor) {
            factor = next
            seen.append(PageZoom.percent(forFactor: factor))
        }
        #expect(seen == [90, 80, 75, 67, 50, 33, 25])
        #expect(factor == 0.25)
    }

    @Test func aFactorBetweenPresetsMovesToTheNextOne() {
        let between = PageZoom.factor(forPercent: 120)
        #expect(between == 1.2)
        #expect(PageZoom.zoomedIn(from: between) == 1.25)
        #expect(PageZoom.zoomedOut(from: between) == 1.1)
    }

    @Test func aFactorNearAPresetCountsAsThatPreset() {
        // An engine that stores zoom in its own unit hands back a factor a hair off the preset it was given.
        #expect(PageZoom.percent(forFactor: 1.1000000000001) == 110)
        #expect(PageZoom.zoomedIn(from: 1.0999999999999) == 1.25)
        #expect(PageZoom.zoomedOut(from: 0.9000000000001) == 0.8)
        #expect(PageZoom.isActualSize(1.0000000000001))
        #expect(!PageZoom.isActualSize(1.1))
    }

    @Test func actualSizeIsExactlyOne() {
        #expect(PageZoom.actualSize == 1)
        #expect(PageZoom.zoomedIn(from: PageZoom.factor(forPercent: 90)) == 1)
        #expect(PageZoom.zoomedOut(from: PageZoom.factor(forPercent: 110)) == 1)
        #expect(PageZoom.percent(forFactor: PageZoom.actualSize) == 100)
    }

    @Test func theEndsStopStepping() {
        #expect(PageZoom.zoomedIn(from: 5) == nil)
        #expect(PageZoom.zoomedOut(from: 0.25) == nil)
    }

    @Test func aFactorNoEngineCouldStoreReadsAsTheNearestSize() {
        #expect(PageZoom.percent(forFactor: .nan) == 100)
        #expect(PageZoom.percent(forFactor: .infinity) == 100)
        #expect(PageZoom.percent(forFactor: 0) == 1)
        #expect(PageZoom.percent(forFactor: -2) == 1)
        #expect(PageZoom.percent(forFactor: 1e9) == 10_000)
        #expect(PageZoom.zoomedIn(from: -2) == 0.25)
    }
}
