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
            canGoForward: state.canGoForward,
            isAudible: state.isAudible,
            isCapturingVideo: state.isCapturingVideo,
            isCapturingAudio: state.isCapturingAudio
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
            requestedSize: request.requestedSize.map { PopupSize(width: $0.width, height: $0.height) },
            windowFeatures: PopupWindowFeatures(
                x: request.windowFeatures.x?.intValue,
                y: request.windowFeatures.y?.intValue,
                width: request.windowFeatures.width?.intValue,
                height: request.windowFeatures.height?.intValue,
                isPopup: request.windowFeatures.isPopup
            ),
            clickModifiers: PopupClickModifiers(
                command: request.clickModifiers.contains(.command),
                shift: request.clickModifiers.contains(.shift)
            )
        )
    }
}

extension BowPopupRequest.Decision {
    init(_ decision: PopupDecision) {
        self =
            switch decision {
            case .foregroundTab: .foregroundTab
            case .backgroundTab: .backgroundTab
            // The engine creates a panel's page as it does a tab's, and the app shows it in the panel.
            case .popupPanel: .foregroundTab
            case .window: .window
            case .block: .block
            }
    }
}

extension EngineKeyEvent {
    init(_ event: BowKeyEvent) {
        let kind: Kind =
            switch event.kind {
            case .keyDown: .keyDown
            case .keyUp: .keyUp
            case .character: .character
            }
        var modifiers: KeyModifiers = []
        if event.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if event.modifiers.contains(.control) { modifiers.insert(.control) }
        if event.modifiers.contains(.option) { modifiers.insert(.option) }
        if event.modifiers.contains(.command) { modifiers.insert(.command) }
        self.init(
            kind: kind,
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers,
            isInEditableField: event.isInEditableField
        )
    }
}

extension AuthChallenge {
    init(_ challenge: BowAuthChallenge) {
        self.init(
            url: challenge.url,
            host: challenge.host,
            port: challenge.port,
            realm: challenge.realm,
            scheme: challenge.scheme,
            isProxy: challenge.fromProxy
        )
    }
}

extension CertificateError {
    init(_ error: BowCertificateError) {
        self.init(url: error.url, code: error.code)
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
