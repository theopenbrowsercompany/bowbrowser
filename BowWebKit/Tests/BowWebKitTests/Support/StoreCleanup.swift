import Foundation
import WebKit

/// The identified website data stores one test makes, removed when it ends. A store made with
/// `WKWebsiteDataStore(forIdentifier:)` lives on disk past the process, so every test that makes one removes it,
/// and checks WebKit lists none of its IDs afterwards.
@MainActor
final class TestStores {
    /// The IDs of the stores made so far. Only the IDs are kept, so this keeps no store alive.
    private(set) var ids: [UUID] = []

    /// A persistent store under a fresh ID (or `id`), recorded for removal.
    func make(id: UUID = UUID()) -> WKWebsiteDataStore {
        ids.append(id)
        return WKWebsiteDataStore(forIdentifier: id)
    }

    /// Removes every store made, retrying while a web view still holds one (WebKit refuses to remove a store in
    /// use), and returns the IDs WebKit still lists afterwards: empty when the cleanup worked. Call it only once
    /// the test has dropped its web views.
    func removeAll(timeout: Double = 15) async -> [UUID] {
        var left = Set(ids)
        let deadline = Date().addingTimeInterval(timeout)
        while !left.isEmpty, Date() < deadline {
            for id in left {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: id)
                    left.remove(id)
                } catch {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        let listed = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        return ids.filter { listed.contains($0) }
    }
}
