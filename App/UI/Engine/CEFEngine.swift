import AppKit
import BowCore

// The BowCore engine contract over the Objective-C bridge (BowEngine, BowProfile, BowTab). App code talks to the
// engine through the BowCore protocols only; this file is where they meet the bridge. The one AppKit seam the
// protocols leave out on purpose, showing a tab in a view, is the BowWebView extension at the end.

/// The running Chromium engine as a `BrowserEngine`. Create it any time; use it once the engine has started
/// (`engineDidStart`), since it reaches the bridge's `BowEngine.shared` on each call.
@MainActor
final class CEFEngine: BrowserEngine {
    /// One adapter per bridge profile, keyed by the bridge's ID, so a profile always comes back as the same object.
    private var profiles: [String: CEFProfile] = [:]
    /// Callers of `quit()`. The process exits once the engine stops, so they are never resumed; they are kept
    /// rather than dropped so a quit a page cancels leaves its caller waiting for a later quit.
    private var quitWaiters: [CheckedContinuation<Void, Never>] = []

    private var bridge: BowEngine { .shared }

    func createProfile(id: ProfileID, isPersistent: Bool) throws -> any EngineProfile {
        do {
            return adapter(for: try bridge.createProfile(id: id.rawValue, persistent: isPersistent))
        } catch let error as BowEngineError {
            switch error.code {
            case .profileExists: throw EngineError.profileExists(id)
            case .invalidProfileID: throw EngineError.invalidProfileID(id)
            @unknown default: throw error
            }
        }
    }

    func profile(id: ProfileID) -> (any EngineProfile)? {
        bridge.profile(id: id.rawValue).map(adapter(for:))
    }

    /// Closes every tab, then stops the engine. On this engine the process exits once it has stopped, so the
    /// call does not return in practice. A page the person chooses to stay on cancels the quit, as quitting from
    /// the menu does, and the caller keeps waiting for a later quit.
    func quit() async {
        await withCheckedContinuation { continuation in
            quitWaiters.append(continuation)
            BowEngine.quit()
        }
    }

    private func adapter(for profile: BowProfile) -> CEFProfile {
        if let existing = profiles[profile.profileID] { return existing }
        let adapter = CEFProfile(profile)
        profiles[profile.profileID] = adapter
        return adapter
    }
}

/// One bridge profile as an `EngineProfile`.
@MainActor
final class CEFProfile: EngineProfile {
    private let profile: BowProfile

    fileprivate init(_ profile: BowProfile) {
        self.profile = profile
    }

    var profileID: ProfileID { ProfileID(profile.profileID) }
    var isPersistent: Bool { profile.isPersistent }

    func createTab(url: URL) -> any EngineTab {
        CEFTab(profile.createTab(url: url))
    }

    func setPermission(_ setting: SitePermissionSetting, for kind: PermissionKind, on site: PermissionSite) {
        let kinds = BowPermissionRequest.Kind([kind])
        guard !kinds.isEmpty else { return }
        profile.setPermission(allowed: setting == .allow, kinds: kinds, origin: site.url)
    }
}

/// One bridge tab as an `EngineTab`. The adapter is both of the bridge tab's delegates (navigation and UI) and
/// merges what they report into `TabEvent` values for its one `EngineTabDelegate`. Whoever holds the adapter keeps
/// receiving events; the page itself lives until it closes, held or not.
///
/// JavaScript dialogs and context menus need answers the BowCore contract has no API for yet, so the adapter leaves
/// those UI delegate methods out and the engine handles them its own way (its own dialogs, the tab's own "leave
/// this site?" sheet, its own context menu). Permission requests go to the delegate's `decidePermission`.
@MainActor
final class CEFTab: NSObject, EngineTab {
    /// Read only by the host view seam below, never by app logic.
    fileprivate let tab: BowTab

    let tabID: TabID
    let profileID: ProfileID
    weak var delegate: (any EngineTabDelegate)?

    fileprivate init(_ tab: BowTab) {
        self.tab = tab
        tabID = TabID(rawValue: tab.tabID)
        profileID = ProfileID(tab.profileID)
        super.init()
        // The bridge tab holds both weakly; whoever holds this adapter keeps them alive.
        tab.navigationDelegate = self
        tab.uiDelegate = self
    }

    var state: EngineTabState { EngineTabState(tab.state) }
    var isClosed: Bool { tab.isClosed }

    func load(_ url: URL) { tab.load(url) }
    func goBack() { tab.goBack() }
    func goForward() { tab.goForward() }
    func reload() { tab.reload() }
    func stop() { tab.stop() }
    func find(_ text: String, forward: Bool, matchCase: Bool) { tab.find(text, forward: forward, matchCase: matchCase) }
    func stopFind() { tab.stopFind() }

    func close() async -> Bool {
        await withCheckedContinuation { continuation in
            tab.close { closed in
                continuation.resume(returning: closed)
            }
        }
    }

    fileprivate func send(_ event: TabEvent) {
        delegate?.tab(self, didReceive: event)
    }
}

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
        send(.didFail(EngineNavigation(navigation), NavigationError(code: error.code, description: error.errorText)))
    }
}

extension CEFTab: BowTabUIDelegate {
    func tab(_ tab: BowTab, didChangeState state: BowTabState) {
        send(.stateChanged(EngineTabState(state)))
    }

    func tabDidClose(_ tab: BowTab) {
        send(.closed)
    }

    func tab(_ tab: BowTab, didRequestPopup request: BowPopupRequest) {
        send(.popupRequested(PopupRequest(request)))
    }

    func tab(_ tab: BowTab, fullscreenChanged isFullscreen: Bool) {
        send(.fullscreenChanged(isFullscreen))
    }

    func tab(_ tab: BowTab, renderProcessGone reason: BowProcessGoneReason) {
        send(.renderProcessGone(ProcessGoneReason(reason)))
    }

    func tab(_ tab: BowTab, didUpdateFindResult result: BowFindResult) {
        send(
            .findResult(
                FindResult(
                    matchCount: result.matchCount, activeMatch: result.activeMatch, isFinal: result.isFinalUpdate)))
    }

    func tab(
        _ tab: BowTab,
        requestPermission request: BowPermissionRequest,
        decisionHandler: @escaping (BowPermissionRequest.Decision) -> Void
    ) {
        let request = PermissionRequest(origin: request.requestingOrigin, kinds: Set(request.kinds))
        Task { @MainActor [weak self] in
            var decision = PermissionDecision.dismiss
            if let self, let delegate = self.delegate {
                decision = await delegate.tab(self, decidePermission: request)
            }
            switch decision {
            case .allow: decisionHandler(.allow)
            case .deny: decisionHandler(.deny)
            case .dismiss: decisionHandler(.dismiss)
            }
        }
    }
}

// The BowCore values of the bridge's values. The bridge mirrors them one to one.

extension EngineTabState {
    fileprivate init(_ state: BowTabState) {
        self.init(
            tabID: TabID(rawValue: state.tabID),
            url: state.url,
            title: state.title,
            faviconURL: state.faviconURL,
            isLoading: state.isLoading,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward
        )
    }
}

extension EngineNavigation {
    fileprivate init(_ navigation: BowNavigation) {
        let transition: NavigationTransition =
            switch navigation.transition {
            case .link: .link
            case .typed: .typed
            case .formSubmit: .formSubmit
            case .reload: .reload
            case .backForward: .backForward
            case .other: .other
            }
        self.init(url: navigation.url, transition: transition, isUserGesture: navigation.isUserGesture)
    }
}

extension PopupRequest {
    fileprivate init(_ request: BowPopupRequest) {
        let disposition: PopupDisposition =
            switch request.disposition {
            case .foregroundTab: .foregroundTab
            case .backgroundTab: .backgroundTab
            case .popup: .popup
            case .window: .window
            }
        self.init(
            targetURL: request.targetURL,
            disposition: disposition,
            isUserGesture: request.isUserGesture,
            requestedSize: request.requestedSize.map { PopupSize(width: $0.width, height: $0.height) }
        )
    }
}

// The bridge's permission kinds are an option set; BowCore's are a set of cases with the same names.
private let permissionKinds: [(BowPermissionRequest.Kind, PermissionKind)] = [
    (.camera, .camera),
    (.microphone, .microphone),
    (.screenCapture, .screenCapture),
    (.geolocation, .geolocation),
    (.notifications, .notifications),
    (.clipboard, .clipboard),
    (.midiSysex, .midiSysex),
    (.storageAccess, .storageAccess),
    (.windowManagement, .windowManagement),
    (.localFonts, .localFonts),
    (.other, .other),
]

extension Set where Element == PermissionKind {
    fileprivate init(_ kinds: BowPermissionRequest.Kind) {
        self.init(permissionKinds.filter { kinds.contains($0.0) }.map(\.1))
    }
}

extension BowPermissionRequest.Kind {
    fileprivate init(_ kinds: Set<PermissionKind>) {
        self = []
        for (bridgeKind, kind) in permissionKinds where kinds.contains(kind) { insert(bridgeKind) }
    }
}

extension ProcessGoneReason {
    fileprivate init(_ reason: BowProcessGoneReason) {
        self =
            switch reason {
            case .crashed: .crashed
            case .killed: .killed
            case .outOfMemory: .outOfMemory
            case .launchFailed: .launchFailed
            case .other: .other
            }
    }
}

// The AppKit seam: the BowCore protocols have no views, so showing a tab goes through these, in App/UI only.
extension BowWebView {
    /// Shows `tab`, detaching the tab shown before. `tab` must come from `CEFEngine`; a closed tab is not shown.
    func show(_ tab: any EngineTab) {
        guard let tab = tab as? CEFTab else {
            assertionFailure("tab \(tab.tabID) did not come from CEFEngine")
            return
        }
        attach(tab.tab)
    }

    /// True while `tab` is the one this view shows.
    func isShowing(_ tab: any EngineTab) -> Bool {
        guard let attachedTab, let tab = tab as? CEFTab else { return false }
        return attachedTab === tab.tab
    }
}

/// Site icons, the other AppKit seam: BowCore carries a tab's icon address, and the image is loaded here.
@MainActor
enum EngineFavicons {
    /// Loads the icon at `url` for `tab` through the tab's own profile, at most `maxPixelSize` pixels on a side,
    /// and calls `completion` on a later main thread task with the image, or nil when it could not be loaded.
    static func load(
        for tab: any EngineTab,
        from url: URL,
        maxPixelSize: Int,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        guard let tab = tab as? CEFTab else {
            assertionFailure("tab \(tab.tabID) did not come from CEFEngine")
            return
        }
        tab.tab.loadFavicon(at: url, maxPixelSize: UInt(maxPixelSize)) { image in
            MainActor.assumeIsolated { completion(image) }
        }
    }
}
