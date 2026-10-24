import AppKit
import BowCore

// The bridge tab's navigation delegate calls, as `TabEvent` values and policy questions.

extension CEFTab: BowTabNavigationDelegate {
    func tab(_ tab: BowTab, decidePolicyFor navigation: BowNavigation) -> BowNavigation.Policy {
        switch delegate?.tab(self, decidePolicyFor: EngineNavigation(navigation)) ?? .allow {
        case .allow: .allow
        case .cancel: .cancel
        }
    }

    func tab(_ tab: BowTab, didStartNavigation navigation: BowNavigation) {
        send(.didStartNavigation(EngineNavigation(navigation)))
    }

    func tab(_ tab: BowTab, didRedirect navigation: BowNavigation) {
        send(.didRedirect(EngineNavigation(navigation)))
    }

    func tab(_ tab: BowTab, didCommit navigation: BowNavigation) {
        send(.didCommit(EngineNavigation(navigation)))
    }

    func tab(_ tab: BowTab, didFinish navigation: BowNavigation, httpStatus: Int) {
        send(.didFinish(EngineNavigation(navigation), httpStatus: httpStatus))
    }

    func tab(_ tab: BowTab, didFail navigation: BowNavigation, error: BowNavigationError) {
        send(.didFail(EngineNavigation(navigation), NavigationError(error)))
    }
}
