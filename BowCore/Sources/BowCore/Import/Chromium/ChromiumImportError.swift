import Foundation

/// Why a Chromium profile file could not be read. Messages are meant to be shown to the person importing.
public enum ChromiumImportError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The file is not there.
    case missingFile(String)
    /// The file is there but not in the expected format.
    case malformed(file: String, reason: String)
    /// The History database could not be copied or opened.
    case database(file: String, reason: String)
    /// Visits left out of the import because their time was unusable.
    case undatedVisits(count: Int)

    public var description: String {
        switch self {
        case .missingFile(let name): return "\(name) was not found in the profile folder"
        case .malformed(let file, let reason): return "\(file) could not be read: \(reason)"
        case .database(let file, let reason): return "\(file) could not be opened: \(reason)"
        case .undatedVisits(let count): return "\(count) visit\(count == 1 ? "" : "s") without a usable date left out"
        }
    }
}

/// Chromium stores times as microseconds since 1601-01-01 UTC (the Windows FILETIME epoch, called WebKit time).
enum ChromiumTime {
    /// Seconds between 1601-01-01 and 1970-01-01.
    static let epochOffsetSeconds: Double = 11_644_473_600

    /// Returns nil for zero or negative values, which Chromium uses for "never".
    static func date(microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - epochOffsetSeconds)
    }
}
