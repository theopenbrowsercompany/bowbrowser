import Foundation

/// The app a link from outside the browser came from.
public struct LinkSource: Equatable, Sendable {
    /// The sending process.
    public var processID: Int32
    /// The bundle identifier of the app the sender belongs to (a helper process counts as the app that contains it),
    /// or nil when the sender is no app (a command line tool, for example `/usr/bin/open`).
    public var bundleID: String?

    public init(processID: Int32, bundleID: String?) {
        self.processID = processID
        self.bundleID = bundleID
    }

    /// The outermost app bundle on `executablePath`, the path of a process's executable, or nil when the path is in no
    /// app bundle. A helper app inside another app (`Slack.app/Contents/Frameworks/Slack Helper.app`) gives the
    /// outer app, so a link a helper sends counts as its parent app's.
    public static func appBundlePath(containing executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        var path = ""
        for component in executablePath.split(separator: "/", omittingEmptySubsequences: true) {
            path += "/" + component
            if component.count > 4, component.lowercased().hasSuffix(".app") { return path }
        }
        return nil
    }
}

/// A link another app asked the browser to open.
public struct IncomingLink: Equatable, Sendable {
    public var url: URL
    /// Who sent it, or nil when the request carried no sender.
    public var source: LinkSource?

    public init(url: URL, source: LinkSource?) {
        self.url = url
        self.source = source
    }

    /// The link for `text`, the address another app sent, or nil unless it is a usable web address (http or https with
    /// a host). Surrounding spaces and newlines are ignored.
    public init?(text: String, source: LinkSource?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty
        else { return nil }
        self.init(url: url, source: source)
    }
}

/// Holds links from other apps until the browser can open them. Links that arrive while it waits (before the engine
/// has started) are kept in order and handed over once it opens; once refused (launch found the app unusable) every
/// link, kept or new, is dropped.
public struct LinkIntake: Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        case open
        case refused
    }

    public private(set) var state: State = .waiting
    public private(set) var pending: [IncomingLink] = []

    public init() {}

    /// Takes a link: returns it when it should open now, or nil when it was kept for later or dropped.
    public mutating func receive(_ link: IncomingLink) -> IncomingLink? {
        switch state {
        case .waiting:
            pending.append(link)
            return nil
        case .open:
            return link
        case .refused:
            return nil
        }
    }

    /// Opens the intake and returns the kept links, oldest first, to open now. Later calls return nothing.
    public mutating func open() -> [IncomingLink] {
        guard state == .waiting else { return [] }
        state = .open
        defer { pending.removeAll() }
        return pending
    }

    /// Drops every kept link and every link from now on.
    public mutating func refuse() {
        state = .refused
        pending.removeAll()
    }
}
