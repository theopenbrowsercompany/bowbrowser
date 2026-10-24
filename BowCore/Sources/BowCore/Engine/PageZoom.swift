import Foundation

/// The zoom steps of a page, the way Chromium based browsers (and Arc) step them: Zoom In and Zoom Out move to the
/// next preset size, and Actual Size goes back to 100%. A zoom factor is a multiplier of the page's size: 1 is 100%,
/// 1.1 is 110% (`EngineTab.zoomFactor`).
public enum PageZoom {
    /// The preset sizes, as percentages, smallest first.
    public static let presets: [Int] = [25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400, 500]

    /// The zoom factor of 100%.
    public static let actualSize: Double = 1

    /// The zoom factor that shows a page at `percent`.
    public static func factor(forPercent percent: Int) -> Double {
        Double(percent) / 100
    }

    /// The size, as a whole percentage, a page at zoom `factor` shows at.
    public static func percent(forFactor factor: Double) -> Int {
        // A factor the engine could not have stored (not a number, not positive, or far past the presets) reads as
        // the nearest size Bow can show.
        guard factor.isFinite else { return 100 }
        return Int((min(max(factor, 0.01), 100) * 100).rounded())
    }

    /// Whether a page at zoom `factor` shows at 100%.
    public static func isActualSize(_ factor: Double) -> Bool {
        percent(forFactor: factor) == 100
    }

    /// The zoom factor one preset larger than `factor`, or nil at the largest.
    public static func zoomedIn(from factor: Double) -> Double? {
        let current = percent(forFactor: factor)
        return presets.first { $0 > current }.map(Self.factor(forPercent:))
    }

    /// The zoom factor one preset smaller than `factor`, or nil at the smallest.
    public static func zoomedOut(from factor: Double) -> Double? {
        let current = percent(forFactor: factor)
        return presets.last { $0 < current }.map(Self.factor(forPercent:))
    }
}
