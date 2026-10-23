import Foundation

/// The start screen an empty Space shows: a greeting by the time of day, the profile's first Favorites as quick links
/// and a hint naming the Space. The decisions live here so the view only draws them.
public enum StartScreen {
    /// The greeting for a local time of day.
    public enum Greeting: String, Sendable, CaseIterable {
        case morning = "Good morning"
        case afternoon = "Good afternoon"
        case evening = "Good evening"

        /// Morning from 5:00 until noon, afternoon from noon until 18:00, evening otherwise (18:00 until 5:00, so a
        /// late night still reads "Good evening"). An hour outside 0 to 23 wraps around the day.
        public init(hour: Int) {
            switch ((hour % 24) + 24) % 24 {
            case 5..<12: self = .morning
            case 12..<18: self = .afternoon
            default: self = .evening
            }
        }

    }

    /// The local hour the greeting is chosen for: `date`'s hour in `calendar`'s time zone.
    public static func hour(at date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date)
    }

    /// The most quick links the screen shows.
    public static let quickLinkLimit = 6
    /// The longest Space name the hint shows whole; a longer one is cut with an ellipsis.
    public static let hintNameLimit = 40

    /// The quick links: the first six Favorites in their sidebar order.
    public static func quickLinks<ID>(from favorites: [ID]) -> [ID] {
        Array(favorites.prefix(quickLinkLimit))
    }

    /// The quick links for the Space on screen: the first six Favorites of its profile that are tabs, in sidebar
    /// order.
    public static func quickLinks(in graph: SidebarGraph) -> [SidebarItemID] {
        quickLinks(from: graph.activeFavoriteIDs.filter { graph[$0]?.tab != nil })
    }

    /// The hint under the screen: "<Space> · press ⌘T to search". The screen only shows in an empty Space, so it
    /// carries no tab count. The name is trimmed, cut to `hintNameLimit` characters with an ellipsis, and reads
    /// "Space" when it is empty.
    public static func hint(spaceName: String) -> String {
        let trimmed = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = trimmed.isEmpty ? "Space" : trimmed
        if name.count > hintNameLimit { name = String(name.prefix(hintNameLimit - 1)) + "\u{2026}" }
        return "\(name) \u{00B7} press \u{2318}T to search"
    }

    /// The hint for Space `space` in `graph`: its name.
    public static func hint(for space: SidebarSpaceID, in graph: SidebarGraph) -> String {
        hint(spaceName: graph.space(space)?.title ?? "")
    }
}
