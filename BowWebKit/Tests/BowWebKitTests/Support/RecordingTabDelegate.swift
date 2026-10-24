import BowCore
import Foundation

/// A tab delegate that records every event a tab sends, in order, and answers navigation policy with a closure,
/// for the tests of the engine's event order.
@MainActor
final class RecordingTabDelegate: EngineTabDelegate {
    private(set) var events: [TabEvent] = []
    private(set) var policyRequests: [EngineNavigation] = []
    var policy: (EngineNavigation) -> NavigationPolicy = { _ in .allow }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        events.append(event)
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        policyRequests.append(navigation)
        return policy(navigation)
    }

    /// The navigation events so far as short names (`start <url>`, `redirect <url>`, `commit <url>`,
    /// `finish <url>`, `fail <url>`), leaving out state changes and every other event.
    var navigation: [String] {
        events.compactMap { event in
            switch event {
            case .didStartNavigation(let n): "start \(n.url.absoluteString)"
            case .didRedirect(let n): "redirect \(n.url.absoluteString)"
            case .didCommit(let n): "commit \(n.url.absoluteString)"
            case .didFinish(let n, _): "finish \(n.url.absoluteString)"
            case .didFail(let n, _): "fail \(n.url.absoluteString)"
            default: nil
            }
        }
    }

    /// Forgets the events and policy requests so far.
    func reset() {
        events = []
        policyRequests = []
    }

    /// Waits until an event matching `match` has arrived and returns the first such.
    func wait(
        for what: String, timeout: Double = 10, _ match: @escaping (TabEvent) -> Bool
    ) async throws -> TabEvent {
        try await waitFor(what, timeout: timeout) { self.events.first(where: match) }
    }
}
