import AppKit
import BowCore
import Foundation

/// The app's browsing history, one `HistoryStore` per engine profile, made when the profile first records a visit.
///
/// A persistent profile keeps `history.sqlite` in its own folder under `History/` in the data directory, beside the
/// sidebar file and apart from it; an ephemeral (in memory) profile keeps its history in memory, so it never reaches
/// the disk. Windows feed it through `HistoryFeature`. A store that cannot be opened is told once on standard error
/// and its profile records nothing.
@MainActor
final class HistoryStores: AppFeature {
    private let directory: URL
    private var stores: [ProfileID: HistoryStore] = [:]
    private var failed: Set<ProfileID> = []

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("History", isDirectory: true)
    }

    /// The history of `profileID`, opened on first use. Nil when it cannot be opened. A profile whose persistence
    /// is unknown counts as ephemeral, so nothing is written for it.
    func store(for profileID: ProfileID, isPersistent: @autoclosure () -> Bool) -> HistoryStore? {
        if let store = stores[profileID] { return store }
        guard !failed.contains(profileID) else { return nil }
        do {
            let store = try HistoryStore(profileID: profileID, isPersistent: isPersistent(), directory: directory)
            stores[profileID] = store
            return store
        } catch {
            failed.insert(profileID)
            FileHandle.standardError.write(
                Data("bow: cannot open the history of \(profileID.rawValue): \(error)\n".utf8))
            return nil
        }
    }

    /// The history of `profileID` if it has recorded anything this run, without opening one.
    func existingStore(for profileID: ProfileID) -> HistoryStore? { stores[profileID] }

    /// Where persistent histories live.
    var historyDirectory: URL { directory }
}
