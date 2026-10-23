import Foundation

/// One profile listed in a Chromium `Local State` file.
public struct ChromiumProfile: Equatable, Sendable {
    /// The folder name inside User Data, such as `Default` or `Profile 1`.
    public let directory: String
    /// The name the person sees in the browser. Falls back to the directory name.
    public let displayName: String

    public init(directory: String, displayName: String) {
        self.directory = directory
        self.displayName = displayName
    }
}

/// Reads the profile list from a Chromium `Local State` file (`profile.info_cache`, a map of directory name to info).
public enum ChromiumProfileList {
    public static let fileName = "Local State"

    public static func parse(data: Data) throws -> [ChromiumProfile] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChromiumImportError.malformed(file: fileName, reason: "not valid JSON")
        }
        guard let object = root as? [String: Any] else {
            throw ChromiumImportError.malformed(file: fileName, reason: "top level is not an object")
        }
        guard let profile = object["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: Any]
        else {
            throw ChromiumImportError.malformed(file: fileName, reason: "no profile.info_cache")
        }
        return cache.compactMap { directory, value -> ChromiumProfile? in
            // The key becomes a folder name, so a key that could point outside User Data is skipped.
            guard let info = value as? [String: Any], !directory.isEmpty,
                !directory.contains("/"), !directory.contains(":"), directory != ".", directory != ".."
            else { return nil }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ChromiumProfile(directory: directory, displayName: name ?? directory)
        }
        .sorted(by: ordered)
    }

    /// Reads `Local State` from a User Data folder.
    public static func load(userDataFolder: URL) throws -> [ChromiumProfile] {
        let url = userDataFolder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ChromiumImportError.missingFile(fileName) }
        guard let data = try? Data(contentsOf: url) else {
            throw ChromiumImportError.malformed(file: fileName, reason: "the file is not readable")
        }
        return try parse(data: data)
    }

    /// `Default` first, then `Profile N` in numeric order, then anything else by name.
    private static func ordered(_ a: ChromiumProfile, _ b: ChromiumProfile) -> Bool {
        func rank(_ p: ChromiumProfile) -> (Int, Int, String) {
            if p.directory == "Default" { return (0, 0, "") }
            if p.directory.hasPrefix("Profile "), let n = Int(p.directory.dropFirst("Profile ".count)) {
                return (1, n, p.directory)
            }
            return (2, 0, p.directory)
        }
        return rank(a) < rank(b)
    }
}
