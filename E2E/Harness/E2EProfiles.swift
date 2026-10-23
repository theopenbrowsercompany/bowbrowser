import Foundation

/// Profiles behind Spaces as a test reads them: the page a window shows after a Space changed profile, the app's
/// registered profiles and the renderer processes running. The Space menu itself goes through `E2ESpaceThemeApp`.
/// E2E/Harness/E2EAppAdapter+Profiles.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EProfilesApp: E2ESpaceThemeApp, E2EStoreApp, E2EWindowEdgesApp {
    /// The page of the tab `page`'s window shows now: `page` itself when it is the one shown, or else the shown tab,
    /// tracked for the test from now on (its earlier events are not seen). Nil while the window shows no page.
    func shownPage(besides page: any E2EPage) throws -> (any E2EPage)?
    /// The app's registered profiles in order, as "<id>:<name>".
    func registeredProfiles() throws -> [String]
    /// How many Chromium renderer processes the app runs now.
    func rendererProcessCount() throws -> Int
}
