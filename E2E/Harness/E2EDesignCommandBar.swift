import Foundation

/// The command bar's part of `E2EDesignLook`, read while the bar shows. Read by
/// E2E/Harness/E2EAppAdapter+DesignCommandBar.swift.
struct E2EDesignCommandBarLook {
    /// The corner radius the panel's content is clipped to, whether it is clipped, and whether the panel's shadow has
    /// a path the size of the panel.
    var radius: Double
    var clips: Bool
    var shadowHasPath: Bool
}
