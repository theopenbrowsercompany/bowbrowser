import Foundation

/// The set of providers behind one command bar, and the ranker that merges what they return.
///
/// Providers run at the same time. A provider that is slow or never answers cannot hold up the
/// others: `updates(for:)` publishes a merged list each time one finishes, and gives up on any
/// that has not answered within `timeout`.
public actor CommandBarRegistry {
    private var providers: [any CommandBarProvider] = []
    private let ranker: CommandBarRanker
    private let timeout: Duration

    public init(ranker: CommandBarRanker = CommandBarRanker(), timeout: Duration = .milliseconds(500)) {
        self.ranker = ranker
        self.timeout = timeout
    }

    /// Adds a provider. Registration order breaks ties between equally ranked results.
    public func register(_ provider: any CommandBarProvider) {
        providers.append(provider)
    }

    /// A stream of merged results for `query`: one element per provider that answers, in the order
    /// they answer, ending when every provider has answered or timed out. Stops early, and cancels
    /// the providers, when the consumer stops listening (for example on the next keystroke).
    public func updates(for query: String) -> AsyncStream<[CommandBarResult]> {
        let providers = providers
        let ranker = ranker
        let timeout = timeout
        let (stream, continuation) = AsyncStream.makeStream(of: [CommandBarResult].self)

        let task = Task {
            var answers = [[CommandBarCandidate]](repeating: [], count: providers.count)
            await withTaskGroup(of: (Int, [CommandBarCandidate])?.self) { group in
                for (index, provider) in providers.enumerated() {
                    group.addTask {
                        await Self.answer(from: provider, index: index, query: query, timeout: timeout)
                    }
                }
                if providers.isEmpty { return }
                for await answer in group {
                    if let (index, candidates) = answer { answers[index] = candidates }
                    continuation.yield(ranker.rank(query: query, candidatesByProvider: answers))
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The final merged results for `query`, after every provider has answered or timed out.
    public func results(for query: String) async -> [CommandBarResult] {
        var latest: [CommandBarResult] = []
        for await update in updates(for: query) { latest = update }
        return latest
    }

    /// Races the provider against the timer with unstructured tasks, so a provider that ignores
    /// cancellation is abandoned instead of awaited.
    private static func answer(
        from provider: any CommandBarProvider, index: Int, query: String, timeout: Duration
    ) async -> (Int, [CommandBarCandidate])? {
        let (race, finish) = AsyncStream.makeStream(of: [CommandBarCandidate]?.self)
        let work = Task { finish.yield(await provider.candidates(for: query)) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            finish.yield(nil)
        }
        defer {
            work.cancel()
            timer.cancel()
            finish.finish()
        }
        var iterator = race.makeAsyncIterator()
        // A timed out provider still counts as having answered, with nothing.
        let first = await iterator.next() ?? nil
        return (index, first ?? [])
    }
}
