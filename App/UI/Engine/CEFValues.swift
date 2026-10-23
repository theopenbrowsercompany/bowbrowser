import AppKit
import BowCore

// The BowCore values of the bridge's values. The bridge mirrors them one to one.

extension EngineTabState {
    init(_ state: BowTabState) {
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
    init(_ navigation: BowNavigation) {
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
    init(_ request: BowPopupRequest) {
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
    init(_ kinds: BowPermissionRequest.Kind) {
        self.init(permissionKinds.filter { kinds.contains($0.0) }.map(\.1))
    }
}

extension BowPermissionRequest.Kind {
    init(_ kinds: Set<PermissionKind>) {
        self = []
        for (bridgeKind, kind) in permissionKinds where kinds.contains(kind) { insert(bridgeKind) }
    }
}

extension ProcessGoneReason {
    init(_ reason: BowProcessGoneReason) {
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
