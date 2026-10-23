import Foundation

/// Identifier the engine assigns to a download. Unique within its profile for the life of the engine.
/// The engine bridge mirrors it as an unsigned 32 bit integer.
public struct DownloadID: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(integerLiteral value: UInt32) {
        self.rawValue = value
    }

    public var description: String { String(rawValue) }
}

/// Where a download is in its life.
public enum DownloadState: String, Equatable, Sendable {
    /// Receiving bytes (or waiting for a destination).
    case inProgress
    /// Paused by the person; resuming continues where it stopped.
    case paused
    /// Every byte is saved at the destination. Final.
    case complete
    /// Cancelled by the person (or refused a destination); any partial file is gone. Final.
    case cancelled
    /// Stopped by an error (network, disk, server). It may resume where it stopped.
    case interrupted

    /// True for states nothing can leave: complete and cancelled.
    public var isFinal: Bool { self == .complete || self == .cancelled }
}

/// An immutable snapshot of one download, as last pushed by the engine.
public struct DownloadItem: Equatable, Sendable, Identifiable {
    public var id: DownloadID
    /// The URL the file comes from, after redirects.
    public var url: URL?
    /// The name the server or page suggested, before the destination is chosen.
    public var suggestedFileName: String
    /// The file being written, or nil until a destination is chosen.
    public var destination: URL?
    public var state: DownloadState
    public var receivedBytes: Int64
    /// The full size, or nil when the server did not say.
    public var totalBytes: Int64?
    public var bytesPerSecond: Int64

    public init(
        id: DownloadID,
        url: URL? = nil,
        suggestedFileName: String = "",
        destination: URL? = nil,
        state: DownloadState = .inProgress,
        receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        bytesPerSecond: Int64 = 0
    ) {
        self.id = id
        self.url = url
        self.suggestedFileName = suggestedFileName
        self.destination = destination
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    /// The name to show: the destination's file name once chosen, otherwise the suggested name.
    public var fileName: String {
        destination?.lastPathComponent ?? (suggestedFileName.isEmpty ? "download" : suggestedFileName)
    }

    /// Between 0 and 1, or nil while the size is unknown. A complete download is always 1.
    public var fractionComplete: Double? {
        if state == .complete { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(receivedBytes) / Double(totalBytes), 1)
    }

    public var canPause: Bool { state == .inProgress }
    public var canResume: Bool { state == .paused || state == .interrupted }
    public var canCancel: Bool { !state.isFinal }
    /// Only downloads that are not running leave the list.
    public var canRemove: Bool { state.isFinal || state == .interrupted }

    /// The progress line the downloads list shows under the file name.
    public var statusText: String {
        let received = Self.byteText(receivedBytes)
        let progress = totalBytes.map { "\(received) of \(Self.byteText($0))" } ?? received
        switch state {
        case .inProgress: return progress
        case .paused: return "Paused, \(progress)"
        case .complete: return "Complete, \(received)"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Failed, \(progress)"
        }
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// What a profile's downloads report, in the order the engine produced it.
public enum DownloadEvent: Equatable, Sendable {
    /// A new download, before its destination is chosen.
    case created(DownloadItem)
    /// Progress, a destination, or a new state.
    case updated(DownloadItem)
    /// The download left the list (see `EngineDownloads.remove`).
    case removed(DownloadID)
}
