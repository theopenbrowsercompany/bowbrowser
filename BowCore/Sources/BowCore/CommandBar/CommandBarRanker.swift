import Foundation

/// Merges the candidates of every provider into one ordered list.
///
/// Rules, strongest first (the numbers are scores; higher sorts earlier):
/// - An exact URL match scores 1000, a URL that starts with the text 600, a title that starts with
///   it 500, a word of the title or URL that starts with every typed word 400, and a typed word
///   found anywhere in the title or URL 200. Text that matches none of these drops the tab or page.
/// - An open tab adds 30 and a history page adds 20, so a tab beats a page with the same match.
/// - The address the person typed scores 900: it beats everything except an exact URL match.
/// - Searching for the typed text scores 250 when no typed address row shows, so it sits below
///   matches that start a word of the title or address but above matches found only inside a word,
///   and 100 while the typed address row shows.
/// - A tab hides the history page and typed address for the same URL, and a history page hides the
///   typed address for its URL, so one URL shows once, as the most useful row.
/// - Equal scores go to the most recently used, then to the provider registered first.
/// - A command (an app action) shows only when the typed words start words of its name, scoring like a title
///   match plus 10. An empty query keeps only tabs and pages, most recently used first.
public struct CommandBarRanker: Sendable {
    public var maxResults: Int

    public init(maxResults: Int = 8) {
        self.maxResults = maxResults
    }

    /// `candidatesByProvider` holds one array per provider, in registration order.
    public func rank(query: String, candidatesByProvider: [[CommandBarCandidate]]) -> [CommandBarResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedKey = URLKey.make(text)
        let words = Self.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)

        struct Entry {
            var candidate: CommandBarCandidate
            var score: Int
            var provider: Int
        }

        var entries: [Entry] = []
        for (provider, candidates) in candidatesByProvider.enumerated() {
            for candidate in candidates {
                switch candidate.kind {
                case .navigation:
                    guard !text.isEmpty else { continue }
                    entries.append(Entry(candidate: candidate, score: 900, provider: provider))
                case .search:
                    guard !text.isEmpty else { continue }
                    entries.append(Entry(candidate: candidate, score: 0, provider: provider))
                case .command:
                    // Only for typed text that matches the command's name; a blank bar lists tabs.
                    guard !text.isEmpty,
                        let match = Self.titleScore(candidate.title, text: Self.fold(text), words: words)
                    else { continue }
                    entries.append(Entry(candidate: candidate, score: match + 10, provider: provider))
                case .openTab, .history:
                    let base = candidate.kind == .history ? 20 : 30
                    if text.isEmpty {
                        entries.append(Entry(candidate: candidate, score: base, provider: provider))
                    } else if let match = Self.matchScore(
                        candidate, typedKey: typedKey, text: Self.fold(text), words: words)
                    {
                        entries.append(Entry(candidate: candidate, score: match + base, provider: provider))
                    }
                }
            }
        }
        // One row per URL: tab over history over typed address. Several tabs may share a URL.
        var tabKeys = Set<String>()
        for entry in entries {
            if case .openTab = entry.candidate.kind { tabKeys.insert(URLKey.make(entry.candidate.url)) }
        }
        var historyKeys = Set<String>()
        var newestHistory: [String: Date] = [:]
        for entry in entries where entry.candidate.kind == .history {
            let key = URLKey.make(entry.candidate.url)
            newestHistory[key] = max(newestHistory[key] ?? .distantPast, entry.candidate.lastUsed ?? .distantPast)
        }
        entries = entries.filter { entry in
            let key = URLKey.make(entry.candidate.url)
            switch entry.candidate.kind {
            case .openTab, .search, .command:
                return true
            case .history:
                guard !tabKeys.contains(key) else { return false }
                // Keep only the newest visit of a URL.
                guard (entry.candidate.lastUsed ?? .distantPast) == newestHistory[key] else { return false }
                return historyKeys.insert(key).inserted
            case .navigation:
                return !tabKeys.contains(key) && newestHistory[key] == nil
            }
        }

        // The search row drops to the bottom only while the typed address row is showing.
        let addressShown = entries.contains { $0.candidate.kind == .navigation }
        for index in entries.indices where entries[index].candidate.kind == .search {
            entries[index].score = addressShown ? 100 : 250
        }

        entries.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let (da, db) = (a.candidate.lastUsed ?? .distantPast, b.candidate.lastUsed ?? .distantPast)
            if da != db { return da > db }
            if a.provider != b.provider { return a.provider < b.provider }
            return a.candidate.title < b.candidate.title
        }
        return entries.prefix(max(0, maxResults)).map { CommandBarResult(candidate: $0.candidate) }
    }

    /// Match quality of a tab or page against the typed text, or nil when it does not match.
    private static func matchScore(
        _ candidate: CommandBarCandidate, typedKey: String, text: String, words: [String]
    ) -> Int? {
        let key = URLKey.make(candidate.url)
        if !typedKey.isEmpty {
            if key == typedKey { return 1000 }
            if key.hasPrefix(typedKey) { return 600 }
        }
        let title = fold(candidate.title)
        if title.hasPrefix(text) { return 500 }
        let haystack = title + " " + key
        let haystackWords = haystack.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.allSatisfy({ word in haystackWords.contains { $0.hasPrefix(word) } }) { return 400 }
        if words.allSatisfy({ haystack.contains($0) }) { return 200 }
        return nil
    }

    /// Match quality of a command's name against the typed text, or nil when it does not match.
    private static func titleScore(_ title: String, text: String, words: [String]) -> Int? {
        let title = fold(title)
        if title.hasPrefix(text) { return 500 }
        let titleWords = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 400 }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// A URL reduced to what identifies the page: scheme, `www.`, fragment and trailing slash are
/// ignored, and the rest is lowercased.
enum URLKey {
    static func make(_ url: URL) -> String {
        make(url.absoluteString)
    }

    static func make(_ text: String) -> String {
        var key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = key.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: .regularExpression) {
            key.removeSubrange(range)
        }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        if let hash = key.firstIndex(of: "#") { key = String(key[..<hash]) }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }
}
