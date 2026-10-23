import Foundation

/// Collects every renderer that ends during the run, from the engine's termination hook, so the runner can fail the
/// test it happened in unless that test declares `expectsRendererCrash`. Chromium's browser tests do the same
/// (NoRendererCrashesAssertion, allowed by ScopedAllowRendererCrashes): a crashed renderer otherwise passes
/// silently, since nothing in the Chromium log marks it and the page just stops answering.
@MainActor
final class E2ERendererCrashWatch {
    struct Termination {
        /// The tab whose own browser the renderer served, or 0 for another browser (a popup).
        let tabID: UInt64
        /// The termination status's name (`crashed`, `killed`, `abnormal`, `oom`, `launch-failed`).
        let status: String
        let errorCode: Int

        var description: String {
            "\(tabID == 0 ? "a popup's renderer" : "the renderer of tab \(tabID)") ended: status=\(status) "
                + "error-code=\(errorCode)"
        }
    }

    private var pending: [Termination] = []

    /// Starts collecting. `onEach` is called with each termination as it comes, for the Chromium log's marks.
    func start(onEach: @escaping @MainActor (Termination) -> Void) {
        BowRendererTerminations.observe { [weak self] tabID, status, errorCode in
            MainActor.assumeIsolated {
                let termination = Termination(tabID: tabID, status: status, errorCode: errorCode)
                self?.pending.append(termination)
                onEach(termination)
            }
        }
    }

    /// The terminations since the last call, which it forgets.
    func take() -> [Termination] {
        defer { pending = [] }
        return pending
    }

    /// The error that fails `test` for `terminations` that came while it ran or while its windows closed.
    static func error(_ terminations: [Termination], in test: String, when: String) -> E2EError {
        E2EError(
            "a renderer ended \(when) \(test), which does not declare expectsRendererCrash: "
                + terminations.map(\.description).joined(separator: "; "))
    }
}
