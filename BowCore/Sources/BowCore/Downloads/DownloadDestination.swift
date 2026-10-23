import Foundation

/// Where a new download goes: straight into the downloads folder under a name no other file has, or, when the
/// person asked to choose each time, a save panel opened on that same suggestion.
public enum DownloadDestination: Equatable, Sendable {
    case save(URL)
    case ask(suggested: URL)

    /// Picks the destination for a download named `suggestedName`. `isTaken` says whether a file name is in use
    /// in `folder` (a file on disk, or a download still writing to it).
    public static func choose(
        suggestedName: String,
        folder: URL,
        askWhereToSave: Bool,
        isTaken: (String) -> Bool
    ) -> DownloadDestination {
        let name = uniqueFileName(safeFileName(suggestedName), isTaken: isTaken)
        let url = folder.appendingPathComponent(name, isDirectory: false)
        return askWhereToSave ? .ask(suggested: url) : .save(url)
    }

    /// The name used when a download suggests none.
    public static let fallbackName = "download"

    /// `name` made safe as one file name: path separators and colons become `_`, control characters go, leading
    /// dots go (so a download is never hidden), and an empty result becomes `fallbackName`.
    public static func safeFileName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                scalars.append("_")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        var safe = String(scalars).trimmingCharacters(in: .whitespaces)
        while safe.hasPrefix(".") { safe.removeFirst() }
        safe = safe.trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? fallbackName : safe
    }

    /// Extensions kept whole when numbering a name, so `a.tar.gz` becomes `a (1).tar.gz`.
    static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    /// `name` when it is free, otherwise the first free `name (n).ext`, numbering from 1 the way Finder and
    /// Chromium do.
    public static func uniqueFileName(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (stem, fileExtension) = split(name)
        var number = 1
        while true {
            let candidate = "\(stem) (\(number))\(fileExtension)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// The name before its extension, and the extension with its dot (empty when there is none).
    private static func split(_ name: String) -> (String, String) {
        let lowered = name.lowercased()
        for compound in compoundExtensions where lowered.hasSuffix("." + compound) && lowered.count > compound.count + 1 {
            let cut = name.index(name.endIndex, offsetBy: -(compound.count + 1))
            return (String(name[..<cut]), String(name[cut...]))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
