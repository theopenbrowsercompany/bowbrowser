import Foundation

/// The brand fonts as a test reads them: whether the app registered the bundled families, what the font tokens
/// resolve to, and the font each text surface actually draws with. E2E/Harness/E2EAppAdapter+Fonts.swift implements
/// it; every action is refused once the test has ended.
@MainActor
protocol E2EFontsApp: E2EApp {
    /// The fonts of `page`'s window now: registration, tokens and the sidebar, command bar and empty state text.
    func fonts(of page: any E2EPage) throws -> E2EFontsLook
}

/// One font as drawn: its family, face name and size in points.
struct E2EFontInfo: Equatable {
    var family: String
    var name: String
    var size: Double
}

/// What `E2EFontsApp.fonts(of:)` reads. Fonts are nil when the surface is not on screen.
struct E2EFontsLook {
    /// Whether the system font list holds the bundled families (they are in it only when the app registered them).
    var nunitoRegistered: Bool
    var fredokaRegistered: Bool
    /// Whether the UI token's font file is inside the app's Resources (not a copy installed on the machine).
    var nunitoFromApp: Bool
    /// Whether JetBrains Mono is registered or bundled (it must not be).
    var jetBrainsPresent: Bool
    /// The bundled files in Resources/Fonts, each non-empty.
    var fontFilesBundled: Bool
    var licenseFilesBundled: Bool
    /// The tokens: BowBrand.ui() and BowBrand.display().
    var uiToken: E2EFontInfo
    var displayToken: E2EFontInfo
    /// The active tab row's title, the Space name label, the command bar's field and the empty state's line
    /// (the start screen's hint for an empty Space, the unloaded tab state's line otherwise).
    var activeRow: E2EFontInfo?
    var spaceName: E2EFontInfo?
    var commandBarField: E2EFontInfo?
    var emptyStateLine: E2EFontInfo?
}
