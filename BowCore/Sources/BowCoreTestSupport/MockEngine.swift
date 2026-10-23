import BowCore
import Foundation

/// An in-memory engine for tests. It records every call and does nothing on its own: tests script
/// what the engine would push with `MockTab.push`, `MockTab.emit` and `MockTab.simulateLoad`.
@MainActor public final class MockEngine: BrowserEngine {
    public enum Call: Equatable, Sendable {
        case createProfile(ProfileID, isPersistent: Bool)
        case quit
    }

    /// Every call made on the engine, in order.
    public private(set) var calls: [Call] = []
    public private(set) var profiles: [ProfileID: MockProfile] = [:]
    public private(set) var hasQuit = false
    private var lastTabID: UInt64 = 0

    public init() {
        profiles[.default] = MockProfile(engine: self, id: .default, isPersistent: true)
    }

    /// The always present persistent profile.
    public var defaultProfile: MockProfile { profiles[.default]! }

    /// Every tab created in any profile and not yet closed, in creation order.
    public var openTabs: [MockTab] {
        profiles.values.flatMap(\.tabs).filter { !$0.isClosed }.sorted { $0.tabID.rawValue < $1.tabID.rawValue }
    }

    public func createProfile(id: ProfileID, isPersistent: Bool) throws -> any EngineProfile {
        calls.append(.createProfile(id, isPersistent: isPersistent))
        guard id.isValid else { throw EngineError.invalidProfileID(id) }
        // Matches the engine: IDs that differ only in case would share one folder.
        guard !profiles.keys.contains(where: { $0.rawValue.caseInsensitiveCompare(id.rawValue) == .orderedSame })
        else { throw EngineError.profileExists(id) }
        let profile = MockProfile(engine: self, id: id, isPersistent: isPersistent)
        profiles[id] = profile
        return profile
    }

    public func profile(id: ProfileID) -> (any EngineProfile)? {
        profiles[id]
    }

    /// Closes every open tab without asking beforeunload, as engine shutdown does.
    public func quit() async {
        calls.append(.quit)
        for tab in openTabs { tab.markClosed() }
        hasQuit = true
    }

    fileprivate func nextTabID() -> TabID {
        lastTabID += 1
        return TabID(rawValue: lastTabID)
    }
}

@MainActor public final class MockProfile: EngineProfile {
    public let profileID: ProfileID
    public let isPersistent: Bool
    /// Every tab created in this profile, in creation order, including closed ones.
    public private(set) var tabs: [MockTab] = []
    private unowned let engine: MockEngine

    fileprivate init(engine: MockEngine, id: ProfileID, isPersistent: Bool) {
        self.engine = engine
        self.profileID = id
        self.isPersistent = isPersistent
    }

    /// Every permission answer stored in this profile's engine settings, in order.
    public private(set) var storedPermissions: [(setting: SitePermissionSetting, kind: PermissionKind, site: PermissionSite)] =
        []

    public func createTab(url: URL) -> any EngineTab {
        let tab = MockTab(id: engine.nextTabID(), profileID: profileID, initialURL: url)
        tabs.append(tab)
        return tab
    }

    public func setPermission(_ setting: SitePermissionSetting, for kind: PermissionKind, on site: PermissionSite) {
        storedPermissions.append((setting, kind, site))
    }
}

@MainActor public final class MockTab: EngineTab {
    public enum Call: Equatable, Sendable {
        case load(URL)
        case goBack
        case goForward
        case reload
        case stop
        case find(String, forward: Bool, matchCase: Bool)
        case stopFind
        case close
    }

    public let tabID: TabID
    public let profileID: ProfileID
    /// The URL the tab was created with.
    public let initialURL: URL
    public private(set) var state: EngineTabState
    public weak var delegate: (any EngineTabDelegate)?

    /// Every call made on the tab, in order.
    public private(set) var calls: [Call] = []
    public private(set) var isClosed = false
    /// Whether the page's beforeunload handler keeps the tab open when `close()` is called.
    public var beforeUnloadCancelsClose = false

    fileprivate init(id: TabID, profileID: ProfileID, initialURL: URL) {
        self.tabID = id
        self.profileID = profileID
        self.initialURL = initialURL
        self.state = EngineTabState(tabID: id)
    }

    public func load(_ url: URL) { calls.append(.load(url)) }
    public func goBack() { calls.append(.goBack) }
    public func goForward() { calls.append(.goForward) }
    public func reload() { calls.append(.reload) }
    public func stop() { calls.append(.stop) }
    public func find(_ text: String, forward: Bool, matchCase: Bool) {
        calls.append(.find(text, forward: forward, matchCase: matchCase))
    }
    public func stopFind() { calls.append(.stopFind) }

    public func close() async -> Bool {
        calls.append(.close)
        guard !isClosed else { return true }
        if beforeUnloadCancelsClose { return false }
        markClosed()
        return true
    }

    /// Marks the tab closed and sends `TabEvent.closed`, as the engine does whoever closed it. Call
    /// it to script a page that closes itself.
    public func markClosed() {
        guard !isClosed else { return }
        isClosed = true
        delegate?.tab(self, didReceive: .closed)
    }

    // MARK: Scripting what the engine pushes

    /// Delivers `event` to the delegate as the engine would. A `stateChanged` event also replaces
    /// `state` first, so the delegate reads the new snapshot.
    public func emit(_ event: TabEvent) {
        if case .stateChanged(let newState) = event {
            precondition(newState.tabID == tabID, "state for tab \(newState.tabID) pushed to tab \(tabID)")
            state = newState
        }
        delegate?.tab(self, didReceive: event)
    }

    /// Pushes a state change made by editing a copy of the current snapshot.
    public func push(_ change: (inout EngineTabState) -> Void) {
        var newState = state
        change(&newState)
        emit(.stateChanged(newState))
    }

    /// Asks the delegate to answer a permission request as the engine would; `.dismiss` without a delegate.
    public func requestPermission(_ request: PermissionRequest) async -> PermissionDecision {
        guard let delegate else { return .dismiss }
        return await delegate.tab(self, decidePermission: request)
    }

    /// Asks the delegate for a navigation policy as the engine would; `.allow` without a delegate.
    public func decidePolicy(for navigation: EngineNavigation) -> NavigationPolicy {
        delegate?.tab(self, decidePolicyFor: navigation) ?? .allow
    }

    /// Plays the events of one successful main frame load: the policy question, start, a loading
    /// state, commit, a committed state with `title`, finish with `httpStatus`, and a final idle
    /// state. Stops after the policy question when the delegate cancels. Returns the policy.
    @discardableResult
    public func simulateLoad(
        _ navigation: EngineNavigation,
        title: String = "",
        faviconURL: URL? = nil,
        httpStatus: Int = 200
    ) -> NavigationPolicy {
        let policy = decidePolicy(for: navigation)
        guard policy == .allow else { return policy }
        emit(.didStartNavigation(navigation))
        push { $0.isLoading = true }
        emit(.didCommit(navigation))
        let hadPage = state.url != nil
        push {
            $0.url = navigation.url
            $0.title = title
            $0.faviconURL = faviconURL
            if navigation.transition != .backForward && navigation.transition != .reload {
                $0.canGoBack = $0.canGoBack || hadPage
                $0.canGoForward = false
            }
        }
        emit(.didFinish(navigation, httpStatus: httpStatus))
        push { $0.isLoading = false }
        return policy
    }

    /// Plays the events of a main frame load that fails before committing.
    public func simulateFailedLoad(_ navigation: EngineNavigation, error: NavigationError) {
        guard decidePolicy(for: navigation) == .allow else { return }
        emit(.didStartNavigation(navigation))
        push { $0.isLoading = true }
        emit(.didFail(navigation, error))
        push { $0.isLoading = false }
    }
}

/// A tab delegate for tests that records every event and answers policy questions with a closure.
@MainActor public final class RecordingTabDelegate: EngineTabDelegate {
    public private(set) var events: [TabEvent] = []
    public private(set) var policyRequests: [EngineNavigation] = []
    public var policy: (EngineNavigation) -> NavigationPolicy = { _ in .allow }

    public init() {}

    public func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        events.append(event)
    }

    public func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        policyRequests.append(navigation)
        return policy(navigation)
    }
}
