import Foundation

/// Stable identifier of a tab in the app's model. It is a UUID so it can be saved and restored,
/// and it is separate from the engine's `TabID`, which only lives as long as the engine does.
public struct BrowserTabID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One tab as the app models it: what the sidebar shows for a page. Plain data with no engine or UI
/// types, and `Codable` so it can be saved as it is.
public struct BrowserTab: Equatable, Sendable, Codable, Identifiable {
    public var id: BrowserTabID
    /// The current address, or nil before anything has loaded.
    public var url: URL?
    /// The page title, empty when the page has none yet.
    public var title: String
    public var faviconURL: URL?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init(
        id: BrowserTabID = BrowserTabID(),
        url: URL? = nil,
        title: String = "",
        faviconURL: URL? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    /// Copies the engine's snapshot into this tab. The tab keeps its own ID.
    public mutating func apply(_ state: EngineTabState) {
        url = state.url
        title = state.title
        faviconURL = state.faviconURL
        isLoading = state.isLoading
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
    }
}
