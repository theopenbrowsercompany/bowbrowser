import Foundation

// The sign in sheet: what it says, and when a window shows it.

extension AuthChallenge {
    /// The longest realm the sheet quotes; a longer one is cut with an ellipsis, so a server cannot fill the sheet.
    public static let maxShownRealmLength = 80

    /// The sign in sheet's title.
    public static let sheetTitle = "Sign in"

    /// The sign in sheet's text, naming who asks in plain words: the site's host (with its port when it is not the
    /// scheme's usual one) and the realm it named, quoted, or the proxy with its port. A site reached over plain HTTP
    /// adds that the connection is not private, as Chrome's sign in dialog does, since the password would travel
    /// unencrypted.
    public var sheetMessage: String {
        if isProxy {
            return "The proxy \(host):\(port) asks for a user name and password."
        }
        let scheme = url?.scheme?.lowercased()
        let defaultPort = scheme == "https" ? 443 : 80
        let site = port == defaultPort || port <= 0 ? host : "\(host):\(port)"
        var message = "\(site) asks for a user name and password"
        let shownRealm = Self.shownRealm(realm)
        message += shownRealm.isEmpty ? "." : " for \u{201C}\(shownRealm)\u{201D}."
        if scheme == "http" {
            message += " Your connection to this site is not private."
        }
        return message
    }

    /// `realm` as the sheet quotes it: one line, trimmed, and cut to `maxShownRealmLength` characters.
    static func shownRealm(_ realm: String) -> String {
        let oneLine = realm.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard oneLine.count > maxShownRealmLength else { return oneLine }
        return String(oneLine.prefix(maxShownRealmLength - 1)) + "\u{2026}"
    }
}

/// One window's sign in requests, following Chrome's login prompt rules (chrome/browser/ui/login): the prompt belongs
/// to the tab that asked and shows as a sheet on the window while the window shows that tab.
///
/// - A request from the tab the window shows comes up at once, and the load waits for the answer.
/// - A request from a tab the window does not show waits, unanswered, and comes up when its tab is shown.
/// - Switching away from a tab whose sheet is up takes the sheet down; the request keeps waiting and comes up again
///   when its tab is shown again.
/// - A new request from a tab replaces its earlier one, which is cancelled (a wrong password makes the server ask
///   again, and the load's earlier request has had its answer by then).
/// - A tab that starts a new navigation, crashes or closes, a closing window and quitting cancel the tab's (or every)
///   request.
///
/// Each request is answered exactly once. A value the window feature drives: each call returns what to do, in order.
public struct SignInPolicy<Tab: Hashable> {
    /// Names one request for as long as the policy holds it.
    public struct RequestID: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: UInt64
        public var description: String { "signin\(rawValue)" }
    }

    /// What the window does, in the order given.
    public enum Action: Equatable {
        /// Show the request's sheet on the window.
        case present(RequestID)
        /// Take the request's sheet down without answering it.
        case dismiss(RequestID)
        /// Answer the request: the user name and password, or nil to cancel.
        case answer(RequestID, AuthCredentials?)
    }

    private struct Entry {
        let id: RequestID
        let tab: Tab
        let challenge: AuthChallenge
        var presented = false
    }

    /// Requests waiting for an answer, oldest first. At most one per tab, and at most one presented.
    private var entries: [Entry] = []
    private var nextID: UInt64 = 1
    /// The tab the window shows.
    public private(set) var shownTab: Tab?
    /// Set once the window closes or the app quits: every later request is cancelled at once.
    public private(set) var isClosed = false

    public init(shownTab: Tab? = nil) {
        self.shownTab = shownTab
    }

    /// The challenge `id` names, while the policy holds it.
    public func challenge(_ id: RequestID) -> AuthChallenge? {
        entries.first { $0.id == id }?.challenge
    }

    /// The request whose sheet is up, if any.
    public var presented: RequestID? {
        entries.first { $0.presented }?.id
    }

    /// Whether `tab` has a request up or waiting for its tab to be shown.
    public func hasRequest(for tab: Tab) -> Bool {
        entries.contains { $0.tab == tab }
    }

    /// Whether any request waits for an answer.
    public var isEmpty: Bool { entries.isEmpty }

    /// `tab` asked to sign in with `challenge`. Returns its ID (also for one answered at once) and what to do.
    public mutating func request(_ challenge: AuthChallenge, from tab: Tab) -> (RequestID, [Action]) {
        let id = RequestID(rawValue: nextID)
        nextID += 1
        guard !isClosed else { return (id, [.answer(id, nil)]) }
        var actions = close(where: { $0.tab == tab })
        var entry = Entry(id: id, tab: tab, challenge: challenge)
        if tab == shownTab {
            entry.presented = true
            actions.append(.present(id))
        }
        entries.append(entry)
        return (id, actions)
    }

    /// The window now shows `tab` (nil for none).
    public mutating func show(_ tab: Tab?) -> [Action] {
        guard tab != shownTab, !isClosed else { return [] }
        var actions: [Action] = []
        if let index = entries.firstIndex(where: { $0.presented }) {
            entries[index].presented = false
            actions.append(.dismiss(entries[index].id))
        }
        shownTab = tab
        if let tab, let index = entries.firstIndex(where: { $0.tab == tab }) {
            entries[index].presented = true
            actions.append(.present(entries[index].id))
        }
        return actions
    }

    /// The person answered request `id` through its sheet, which is already down: Sign In with `credentials`, or
    /// Cancel with nil. Ignored for a request the policy no longer holds or whose sheet is not up.
    public mutating func answered(_ id: RequestID, _ credentials: AuthCredentials?) -> [Action] {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.presented }) else { return [] }
        entries.remove(at: index)
        return [.answer(id, credentials)]
    }

    /// `tab` started a new navigation, or its page's process ended: its request belonged to the load it left.
    public mutating func navigated(_ tab: Tab) -> [Action] {
        close(where: { $0.tab == tab })
    }

    /// `tab` closed (or unloaded).
    public mutating func closed(_ tab: Tab) -> [Action] {
        if tab == shownTab { shownTab = nil }
        return close(where: { $0.tab == tab })
    }

    /// The window is closing, or the app is quitting: every request is cancelled, and later ones are cancelled at once.
    public mutating func closeAll() -> [Action] {
        isClosed = true
        shownTab = nil
        return close(where: { _ in true })
    }

    private mutating func close(where matches: (Entry) -> Bool) -> [Action] {
        var actions: [Action] = []
        for entry in entries where matches(entry) {
            if entry.presented { actions.append(.dismiss(entry.id)) }
            actions.append(.answer(entry.id, nil))
        }
        entries.removeAll(where: matches)
        return actions
    }
}
