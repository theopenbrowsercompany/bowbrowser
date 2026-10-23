import Foundation

/// Held downloads: `_held/<key>/<bytes>/<name>` is a download named `<name>` of `<bytes>` bytes that sends its first
/// chunk, then holds the rest until the test releases `<key>`, and then ends at once. A test sees it in progress for as
/// long as it needs and decides when it ends, instead of racing a timed body. The runner releases every held download
/// after each test, so one a failed test left never hangs the next.
extension E2EFixture {
    /// The address of a held download.
    static func heldDownload(key: String, bytes: Int64, fileName: String) -> URL {
        url("_held/\(key)/\(bytes)/\(fileName)")
    }

    /// Lets the held downloads with `key` finish, and those started with it later run through.
    static func releaseHeld(_ key: String) {
        BowFixtureServer.releaseHeld(key)
    }

    /// Releases every held download; the runner calls it as each test ends.
    static func releaseAllHeld() {
        BowFixtureServer.releaseAllHeld()
    }
}
