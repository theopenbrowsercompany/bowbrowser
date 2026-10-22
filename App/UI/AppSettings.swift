import Foundation

/// Where the app keeps its own settings. Read and write through `defaults`, never `UserDefaults.standard`:
/// e2e runs point it at a throwaway suite so they never read or change the maintainer's settings.
@MainActor
enum AppSettings {
    static var defaults: UserDefaults = .standard
}
