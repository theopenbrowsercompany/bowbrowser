import Foundation

/// The zoom steps of a page, the way Chromium based browsers (and Arc) step them: Zoom In and Zoom Out move to the
/// next preset size, and Actual Size goes back to 100%. A zoom level is the engine's own unit: 0 is 100% and each
/// step of 1 is 1.2 times larger (`EngineTab.zoomLevel`).
public enum PageZoom {
    /// The preset sizes, as percentages, smallest first.
    public static let presets: [Int] = [25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400, 500]

    /// The zoom level of 100%.
    public static let actualSize: Double = 0

    /// The zoom level that shows a page at `percent`.
    public static func level(forPercent percent: Int) -> Double {
        log(Double(percent) / 100) / log(1.2)
    }

    /// The size, as a whole percentage, a page at zoom `level` shows at.
    public static func percent(forLevel level: Double) -> Int {
        // A level the engine could not have stored (not a number, or far past the presets) reads as the nearest size.
        guard level.isFinite else { return 100 }
        return Int((pow(1.2, min(max(level, -50), 50)) * 100).rounded())
    }

    /// The zoom level one preset larger than `level`, or nil at the largest.
    public static func zoomedIn(from level: Double) -> Double? {
        let current = percent(forLevel: level)
        return presets.first { $0 > current }.map(levelOf)
    }

    /// The zoom level one preset smaller than `level`, or nil at the smallest.
    public static func zoomedOut(from level: Double) -> Double? {
        let current = percent(forLevel: level)
        return presets.last { $0 < current }.map(levelOf)
    }

    private static func levelOf(_ percent: Int) -> Double {
        // 100% is exactly 0, so a reset page compares equal.
        percent == 100 ? 0 : level(forPercent: percent)
    }
}
